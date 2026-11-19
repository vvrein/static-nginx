This project builds a statically linked nginx binary.  

The aim is a portable nginx binary, compiled with some third-party modules and, as far as possible, with the standard modules that are `not built by default`. It can be copied across different machines and OSes without compiling it on each of them. Yes, static linking is generally considered bad, but it lets you run the same binary on your whole machinery zoo.  
Another use case is a `FROM scratch` docker container, although the single nginx binary is ~3x larger than an alpine image with nginx installed (default install, no additional modules).  

Third-party modules included:  
- https://github.com/vozlt/nginx-module-vts  
- https://github.com/openresty/headers-more-nginx-module
- https://github.com/openresty/echo-nginx-module
- https://github.com/nginx/njs (built with QuickJS)
- https://github.com/nginx/nginx-acme


Usage:  
```
docker build . -t nginx:nginx
docker create --name nginx nginx:nginx
docker cp nginx:/tmp/src/nginx/objs/nginx nginx
docker rm nginx
```


To run tests:  
```
docker run --rm -it nginx:nginx sh
# nginx-tests
cd /tmp/src/nginx-tests; sudo -u nobody env PATH=/tmp/src/openssl/apps/:$PATH TEST_NGINX_BINARY=/tmp/src/nginx/objs/nginx prove .
# njs
cd /tmp/src/nginx-njs; sudo -u nobody env PATH=/tmp/src/openssl/apps/:$PATH TEST_NGINX_BINARY=/tmp/src/nginx/objs/nginx prove -r -I /tmp/src/nginx-tests/lib/ nginx/t
# nginx-module-vts
cd /tmp/src/nginx-vts; PATH=/tmp/src/nginx/objs/:$PATH prove -r $(ls -1 t/ | grep '[[:digit:]]' | grep -v lua | sed 's/^/t\//')
# nginx-acme
cd /tmp/src/nginx-acme; sudo -u nobody env PATH=/tmp/src/openssl/apps/:$PATH TEST_NGINX_BINARY=/tmp/src/nginx/objs/nginx TEST_NGINX_GLOBALS="" prove -I /tmp/src/nginx-tests/lib t/
```


Known test failures:  

With OpenSSL 4.1.0 (first used with nginx 1.31.9), these nginx-tests are expected to fail:
```
grpc_ssl.t                  tests 1-8 (then "Bad plan", exits after test 10)
proxy_ssl_crl.t             tests 1, 5
proxy_ssl_verify.t          test 4
ssl_cache.t                 test 4
stream_proxy_ssl_verify.t   test 4
uwsgi_ssl_verify.t          test 4
```
and these njs tests (`nginx-njs/nginx/t/`):
```
js_fetch_https.t            test 4
js_fetch_https_keepalive.t  tests 2-6
js_fetch_proxy_https.t      tests 1-7
js_fetch_proxy_keepalive.t  tests 1-6
stream_js_fetch_https.t     tests 2, 5
```
Cause: OpenSSL 4.1.0 no longer falls back to the subject `commonName` when it checks a hostname
against a certificate without a subjectAltName. `X509_check_host()` now checks the CN only when
`X509_CHECK_FLAG_ALWAYS_CHECK_SUBJECT` is set (see https://github.com/openssl/openssl/pull/31982).
nginx calls `X509_check_host()` with flags `0` and these tests use CN-only certificates, so the upstream
check fails with `upstream SSL certificate does not match "<name>"` and nginx returns 502
(for njs `fetch()`: `js http SSL certificate does not match "<name>"`).  
This is accepted as is: the binary works, the tests are outdated. In practice, upstream certificates
need a SAN to pass `proxy_ssl_verify`, `grpc_ssl_verify`, `uwsgi_ssl_verify`, stream `proxy_ssl_verify`
and `js_fetch_verify`.  
To reproduce: `openssl verify -CAfile c.crt -verify_hostname <cn> c.crt` on a CN-only certificate fails with `hostname mismatch`.  
Check again after bumping nginx-tests, nginx or OpenSSL, and remove this note once the tests pass.

njs `js_native_module.t` and `stream_js_native_module.t` are expected to be skipped ("no QuickJS native
module support"), probably because a static binary can't load shared native modules. They take the QuickJS
include path from `nginx -V` after a `chdir` into their own directory, so `--with-cc-opt` must use an absolute
`-I/tmp/src/quickjs`: with a relative `-I../quickjs` they fail to compile `quickjs.h` instead of skipping.

nginx-acme tests need `pebble` and `perl-io-socket-inet6` (installed in the image). With Alpine's pebble 2.8.0,
`acme_external_account.t`, `acme_profiles.t`, `acme_renewal.t` and `acme_renewal_info.t` are skipped (no EAB /
profile / validity / ARI support in that pebble). The binary must be linked with `-no-pie` (see the comment in the
Dockerfile): as a static-PIE, nginx-acme busy-loops at 100% CPU on its first ACME request and the tests hang.


Useful links:  
- https://github.com/agile6v/awesome-nginx
- https://nginx.org/en/docs/configure.html
- https://github.com/jingjingxyk/build-static-nginx
- https://gist.github.com/rjeczalik/7057434


About nginx-tests:  
https://github.com/nginx/nginx-tests/issues/17
```
nginx-tests, as primarily a developer test suite, is used to run against nginx mainline and the latest stable branch.
Once a new stable branch is created, support for the previous one that becomes legacy is removed.
Occasionally, support for the previous stable branch may be extended, for practical reasons.
```


Listing available `--with-*` configure options:  
```
grep -hoPR -- '--with-[^\s=\)"\\]+' auto/ | grep -vP -- '-asm|-opt|-cc|-cpp|perftools_module|degradation_module|md5|sha1|imap|ipv6'  | sort | uniq
curl -qs  https://nginx.org/en/docs/configure.html | grep -oP -- '--with-[^<>=\s]+'  | sort | uniq | grep -vP -- '-cc|-cpp|-cpu|-opt|test_module|perftools_module|geoip_module'
```
