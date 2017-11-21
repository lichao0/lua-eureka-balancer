# lua-eureka-balancer

#nginx.conf

...

http {

    # 配置共享缓存区
    lua_shared_dict eureka_balancer 128m;
   
    init_worker_by_lua_block {
        -- init eureka balancer
        local eureka_balancer = require "resty.xtc.eureka_balancer"
        local i_eureka_balancer = eureka_balancer:new({dict_name="eureka_balancer"})
        --配置eureka服务器地址
        i_eureka_balancer.set_eureka_service_url({"127.0.0.1:1111","127.0.0.1:1112"})
        --配置监听的服务名称
        i_eureka_balancer.watch_service({"demo-service","demo-service2"})
    }

    upstream up_demo {
        server 127.0.0.1:666; # Required, because empty upstream block is rejected by nginx (nginx+ can use 'zone' instead)
        balancer_by_lua_block {         
            --定义后端服务的服务名称
            local service_name = "demo-service"

            --服务发现+负载均衡
            local eureka_balancer = require "resty.xtc.eureka_balancer"
            local i_eureka_balancer = eureka_balancer:new({dict_name="eureka_balancer"}) 

            --i_eureka_balancer.ip_hash(service_name) --IP Hash负载算法
            i_eureka_balancer.round_robin(service_name) --轮询负载算法
        }
    }

    server {
        listen 80;
        
        location /test {
            proxy_pass  http://up_demo/;
            proxy_set_header Host $http_host";
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto  $scheme;
        }
    }

}
