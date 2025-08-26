This is the project that builds statically linked nginx binary  

It also incorporates modules:  
- https://github.com/vozlt/nginx-module-vts  
- https://github.com/openresty/headers-more-nginx-module


Usage:
```
docker build . -t nginx:nginx
docker create --name nginx nginx:nginx
docker cp nginx:/tmp/src/nginx/objs/nginx nginx
```


Project aim is to make portable nginx binary, compiled with some custom modules, and as much as it might be, standard modules that `is not built by default`, which can be spread accross different machices and OS'es with no need to compile statically or dynamically on every machine. Yup, in general - static linking is bad, nevertheless it allows you run same binary on you machinery zoo.  
Another use case - use it in your `FROM scratch` docker container, although size of single nginx binary is ~3x times larger than alpine image with nginx installed (default install, no additional modules).  


Some links than are nice to mention here:  
- https://github.com/agile6v/awesome-nginx
- https://nginx.org/en/docs/configure.html
- https://github.com/jingjingxyk/build-static-nginx
- https://gist.github.com/rjeczalik/7057434


About nginx-tests:
```
nginx-tests, as primarily a developer test suite, is used to run against nginx mainline and the latest stable branch.
Once a new stable branch is created, support for the previous one that becomes legacy is removed.
Occasionally, support for the previous stable branch may be extended, for practical reasons.
```
https://github.com/nginx/nginx-tests/issues/17


```
grep -hoPR -- '--with-[^\s=\)"\\]+' auto/ | grep -vP -- '-asm|-opt|-cc|-cpp|perftools_module|degradation_module|md5|sha1|imap|ipv6'  | sort | uniq
curl -qs  https://nginx.org/en/docs/configure.html | grep -oP -- '--with-[^<>=\s]+'  | sort | uniq | grep -vP -- '-cc|-cpp|-cpu|-opt|test_module|perftools_module|geoip_module'
```
