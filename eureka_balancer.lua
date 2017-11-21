-- eureka_balancer.lua
-- 
-- author lichao

local http = require "resty.http"
local balancer = require "ngx.balancer"
local json = require "cjson"

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
  new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 100)

_M.VERSION = "0.0.1"

local mt = { __index = _M }

local default_dict_name = "eureka_balancer"

-- refresh success idle time (s)
local watch_refresh_idle_time = 10

-- refresh failed retry idle time (s)
local refresh_retry_idle_time = 5

-- max idle timeout (in ms) when the connection is in the pool
local http_max_idle_timeout = 60000
-- the maximal size of the pool every nginx worker process
local http_pool_size = 10

local function _timer(...)
  local ok, err = ngx.timer.at(...)
  if not ok then
    ngx.log(ngx.ERR, "eureka.balancer: failed to create timer: ", err)
  end
end

function split(s, p)
    local rt= {}
    string.gsub(s, '[^'..p..']+', function(w) table.insert(rt, w) end )
    return rt
end

-- build eureka service uri
local function build_eureka_uri(eureka_url_index)
  local uri = _M.eureka_service_urls[eureka_url_index]
  local ipAddr = split(uri, ":")
  local ip = ipAddr[1]
  local port = ipAddr[2]
  return ip, port
end

-- build eureka request params
local function build_eureka_params(service_name)
  local uri = "/eureka/apps/" .. service_name
  local params = {path=uri, method="GET", headers={["Accept"]="application/json"}}
  return params
end

local function incr_eureka_url_index(eureka_url_index)
  if eureka_url_index >= #_M.eureka_service_urls then
    eureka_url_index = 1
  else
    eureka_url_index = eureka_url_index + 1
  end
  return eureka_url_index
end

-- parse eureka result
local function parse_service(body)
  local ok, res_json = pcall(function()
    return json.decode(body)
  end)
  if not ok then
    return nil, "JSON decode error"
  end

  local service = {}
  service.upstreams = {}

  for k, v in pairs(res_json) do
    local passing = true
    local instances = v["instance"]

    for i, instance in pairs(instances) do
      local status = instance["status"]
      if status == "UP" then
        local ipAddr = instance["ipAddr"]
        local port = instance["port"]["$"]
        table.insert(service.upstreams, {ip=ipAddr, port=port})
      end
    end

    --ngx.log(ngx.INFO, "eureka.balancer: instance", json.encode(service.upstreams))
  end
  return service
end

-- cache service to ngx shared dict
local function cache_service(service_name, service)
  if not _M.shared_cache then
    return nil
  end
  ngx.log(ngx.INFO, "eureka.balancer: cache service to ngx shared: ", service_name, " ", json.encode(service))
  _M.shared_cache:set(service_name, json.encode(service))  
end

-- get service from ngx shared dict
local function aquire_service(service_name)
  if not _M.shared_cache then
    return nil    
  end
  local service_json = _M.shared_cache:get(service_name)
  
  ngx.log(ngx.INFO, "eureka.balancer: aquire service from ngx shared: service_name: ", service_name, " ", service_json)

  return service_json and json.decode(service_json) or nil
end

-- only update upstreams if service already exist (round robin cursor)
local function cache_service_upstreams(service_name, service)
  if not _M.shared_cache then
    return nil    
  end
  ngx.log(ngx.INFO, "eureka.balancer: cache service upstreams to ngx shared: ", service_name, " ", json.encode(service))

  local cached_service = aquire_service(service_name)
  if cached_service ~= nil then
    cached_service.upstreams = service.upstreams
    cache_service(service_name, cached_service)
  else
    cache_service(service_name, service)
  end
end

-- refresh service from eureka
local function refresh_service(service_name, eureka_url_index)
  local httpc = http:new()
  --connect_timeout, send_timeout, read_timeout (in ms)
  httpc:set_timeouts(3000, 10000, 10000)
  local params = build_eureka_params(service_name)  
  local s_ip, s_port = build_eureka_uri(eureka_url_index)

  ngx.log(ngx.INFO, "eureka.balancer: refresh_service : ", eureka_url_index, " ", s_ip, ":", s_port)

  local ok, err = httpc:connect(s_ip, s_port)
  if err ~= nil then
    ngx.log(ngx.ERR, "eureka.balancer: failed to connect eureka server: ", s_ip, ":", s_port, " ", err)
    return nil, err
  end 

  local res, err = httpc:request(params)
  if err ~= nil then
    ngx.log(ngx.ERR, "eureka.balancer: failed to request eureka server: ", s_ip, ":", s_port, " ", err)
    return nil, err
  end

  if res.status ~= 200 then
    return nil, "bad response code: " .. res.status
  end

  local body = res:read_body()
  local service, err = parse_service(body)
  if err ~= nil then
    ngx.log(ngx.ERR, "eureka.balancer: failed to parse eureka service response: ", s_ip, ":", s_port, " ", err)
    return nil, err
  end

  local ok, err = httpc:set_keepalive(http_max_idle_timeout, http_pool_size)
  --local ok, err = httpc:set_keepalive()
  if err ~= nil then
    ngx.log(ngx.ERR, "eureka.balancer: failed to set keepalive for http client: ", err)
  end
  return service
end


local function watch(premature, service_name, eureka_url_index)
  if premature then
    return nil
  end

  eureka_url_index = eureka_url_index or 1

  local service, err = refresh_service(service_name, eureka_url_index)
  if err ~= nil then
    ngx.log(ngx.ERR, "eureka.balancer: failed watching service: ", service_name)

    eureka_url_index = incr_eureka_url_index(eureka_url_index)

    ngx.log(ngx.ERR, "eureka.balancer: failed watching service eureka_url_index: ", eureka_url_index)

    _timer(refresh_retry_idle_time, watch, service_name, eureka_url_index)
    return nil
  end

  service.name = service_name
  cache_service_upstreams(service_name, service)

  _timer(watch_refresh_idle_time, watch, service_name, eureka_url_index)
end

-- watch services
function _M.watch_service(service_list)
  if ngx.worker.id() > 0 then
    return
  end
  for k,v in pairs(service_list) do
    _timer(0, watch, v, 1)
  end
end

-- round_robin incr service.cursor
local function incr_service_cursor(service)
  service = service or {}
  if service.cursor == nil then
    service.cursor = 1
  else
    service.cursor = service.cursor + 1
  end
  if service.cursor > #service.upstreams then
    service.cursor = 1
  end
  return service.cursor
end

--round_robin
function _M.round_robin(service_name)
  local service = aquire_service(service_name)
  if service == nil then
    ngx.log(ngx.ERR, "eureka.balancer: service not found: ", service_name)
    return ngx.exit(500)
  end
  if service.upstreams == nil or #service.upstreams == 0 then
    ngx.log(ngx.ERR, "eureka.balancer: no peers for service: ", service_name)
    return ngx.exit(500)
  end

  incr_service_cursor(service)

  -- TODO: https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/balancer.md#get_last_failure
  if not balancer.get_last_failure() then
    balancer.set_more_tries(#service.upstreams - 1)
  end
  -- Picking next backend server
  local backend_server = service.upstreams[service.cursor]
  
  -- update service cursor
  cache_service(service_name, service)

  local ok, err = balancer.set_current_peer(backend_server["ip"], backend_server["port"])
  if not ok then
    ngx.log(ngx.ERR, "eureka.balancer: failed to set the current peer: ", err)
    return ngx.exit(500)
  end
end

--ip_hash
function _M.ip_hash(service_name)
  local service = aquire_service(service_name)
  if service == nil then
    ngx.log(ngx.ERR, "eureka.balancer: service not found: ", service_name)
    return ngx.exit(500)
  end
  local bs_size = #service.upstreams
  if service.upstreams == nil or bs_size == 0 then
    ngx.log(ngx.ERR, "eureka.balancer: no peers for service: ", service_name)
    return ngx.exit(500)
  end

  local remote_ip = ngx.var.remote_addr
  --local remote_port = ngx.var.remote_port
  local hash_key = remote_ip
  local hash = ngx.crc32_long(hash_key)
  local index = (hash % bs_size) + 1

  local backend_server = service.upstreams[index]
  local ok, err = balancer.set_current_peer(backend_server["ip"], backend_server["port"])
  if not ok then
    ngx.log(ngx.ERR, "eureka.balancer: failed to set the current peer: ", err)
    return ngx.exit(500)
  end
end


local function set_shared_dict_name(dict_name)
  dict_name = dict_name or default_dict_name
  _M.shared_cache = ngx.shared[dict_name]
  if not _M.shared_cache then
    ngx.log(ngx.ERR, "eureka.balancer: unable to access shared dict ", dict_name)
    return ngx.exit(ngx.ERROR)
  end
end

-- set eureka service urls
function _M.set_eureka_service_url(eureka_service_urls)
  _M.eureka_service_urls = eureka_service_urls
  if not _M.eureka_service_urls then
    ngx.log(ngx.ERR, "eureka.balancer: require set eureka_service_urls")
    return ngx.exit(ngx.ERROR)
  end
end

function _M.new(self, opts)
  opts = opts or {}
  if opts.dict_name ~= nil then
    set_shared_dict_name(opts.dict_name)
  end
  return setmetatable({}, mt)
end

return _M