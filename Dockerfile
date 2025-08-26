FROM alpine:latest AS builder

RUN mkdir -p /tmp/src
RUN apk --update add wget build-base perl linux-headers autoconf libtool automake python3 pkgconf python3-dev # for builind
RUN apk --update add perl-test-harness-utils perl-test-nginx perl-io-socket-ssl perl-cgi-fast perl-cryptx uwsgi-python3 sudo prometheus # for testing
WORKDIR /tmp/src


ENV NGINX_VER="1.28.0"
ENV NGINX_SRC="http://nginx.org/download/nginx-${NGINX_VER}.tar.gz"

ENV PCRE_VER="10.45"
ENV PCRE_SRC="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VER}/pcre2-${PCRE_VER}.tar.gz"

ENV OPENSSL_VER="3.5.2"
ENV OPENSSL_SRC="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"

ENV ZLIB_VER="1.3.1"
ENV ZLIB_SRC="https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz"

ENV LIBXSLT_VER="1.1.42"
ENV LIBXSLT_SRC="https://gitlab.gnome.org/GNOME/libxslt/-/archive/v${LIBXSLT_VER}/libxslt-v${LIBXSLT_VER}.tar.gz"

ENV LIBXML_VER="2.14.5"
ENV LIBXML_SRC="https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML_VER}/libxml2-v${LIBXML_VER}.tar.gz"

ENV NGX_VTSMOD_SRC="https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v0.2.4.tar.gz"


RUN I=nginx \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGINX_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=pcre \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${PCRE_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=openssl \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${OPENSSL_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=zlib \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${ZLIB_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=libxslt \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${LIBXSLT_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=libxml \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${LIBXML_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

RUN I=nginx-vts \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_VTSMOD_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

ENV NGX_MRHDRS_SRC="https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v0.38.tar.gz"
RUN I=nginx-more-headers \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_MRHDRS_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

ENV NGX_ECHO_SRC="https://github.com/openresty/echo-nginx-module/archive/refs/tags/v0.63.tar.gz"
RUN I=nginx-echo \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_ECHO_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

ENV NGX_TESTS_SRC="https://github.com/openresty/lua-nginx-module/archive/refs/tags/v0.10.28.tar.gz"
RUN I=nginx-tests \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_TESTS_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

#ENV NGX_DVLKIT_SRC="https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v0.3.4.tar.gz"
#RUN I=nginx-devel-kit \
#    && mkdir ${I} \
#    && wget -O ${I}.tar.gz ${NGX_DVLKIT_SRC} \
#    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}
#
#ENV NGX_LUA_SRC="https://github.com/openresty/lua-nginx-module/archive/refs/tags/v0.10.28.tar.gz"
#RUN I=nginx-lua \
#    && mkdir ${I} \
#    && wget -O ${I}.tar.gz ${NGX_LUA_SRC} \
#    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}
#
#ENV LUAJIT_SRC="https://github.com/openresty/luajit2/archive/refs/tags/v2.1-20250529.tar.gz"
#RUN I=luajit2 \
#    && mkdir ${I} \
#    && wget -O ${I}.tar.gz ${LUAJIT_SRC} \
#    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I} \
#    && cd ${I} \
#    && make -j $(nproc) \
#    && make install
#
#ENV LUAJIT_LIB=/usr/local/lib
#ENV LUAJIT_INC=/usr/local/include/luajit-2.1
#    --add-module=../nginx-devel-kit \
#    --add-module=../nginx-lua \

ENV CFLAGS="-O2 -static -static-libgcc -fPIC"
ENV LDFLAGS="-static"
RUN cd libxml \
    && ./autogen.sh \
    && make -j $(nproc) \
    && make install

RUN cd libxslt \
    && ./autogen.sh --with-libxml-src=../libxml \
    && make -j $(nproc) \
    && make install

RUN cd nginx && ./configure \
    --with-cc-opt='-g -fstack-protector-strong -Wformat -Werror=format-security -Wdate-time -D_FORTIFY_SOURCE=2 -O2 -static -static-libgcc -fPIC -I/usr/local/include/libxml2 -I/usr/local/include/libxslt' \
    --with-ld-opt='-Wl,-z,relro -Wl,-z,now -fPIC -static -lxml2 -lxslt' \
    --add-module=../nginx-vts \
    --add-module=../nginx-echo \
    --add-module=../nginx-more-headers \
    --with-openssl=../openssl \
    --with-pcre=../pcre \
    --with-zlib=../zlib \
    --with-cpu-opt=generic\
    --prefix=/usr/share/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --http-log-path=/var/log/nginx/access.log \
    --error-log-path=stderr \
    --lock-path=/var/lock/nginx.lock \
    --pid-path=/run/nginx.pid \
    --modules-path=/usr/lib/nginx/modules \
    --http-client-body-temp-path=/var/lib/nginx/body \
    --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
    --http-proxy-temp-path=/var/lib/nginx/proxy \
    --http-scgi-temp-path=/var/lib/nginx/scgi \
    --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
    --with-compat  \
    --with-debug \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module  \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_xslt_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-pcre-jit \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-threads \
    --with-file-aio

RUN cd nginx && make -j $(nproc)
# to run nginx-tests tests
# sudo -u nobody env PATH=/tmp/src/openssl/apps/:$PATH TEST_NGINX_BINARY=/tmp/src/nginx/objs/nginx prove -v .

# to run nginx-module-vts tests
# PATH=/tmp/src/nginx/objs/:$PATH prove  -r $(ls -1 t/ | grep '[[:digit:]]' | grep -v lua | sed 's/^/t\//')

#  --with-http_degradation_module     enable ngx_http_degradation_module
#  --with-select_module               enable select module
#  --with-poll_module                 enable poll module
#  --with-http_perl_module            enable ngx_http_perl_module
#  --with-http_perl_module=dynamic    enable dynamic ngx_http_perl_module

#  --with-http_image_filter_module    enable ngx_http_image_filter_module
#  --with-http_image_filter_module=dynamic
#  --with-http_geoip_module           enable ngx_http_geoip_module
#  --with-http_geoip_module=dynamic   enable dynamic ngx_http_geoip_module
#  --with-stream_geoip_module         enable ngx_stream_geoip_module
#  --with-stream_geoip_module=dynamic enable dynamic ngx_stream_geoip_module
#  --with-google_perftools_module     enable ngx_google_perftools_module
#  --with-cpp_test_module             enable ngx_cpp_test_module
#  --with-libatomic                   force libatomic_ops library usage
#  --with-libatomic=DIR               set path to libatomic_ops library sources



#RUN <<EOF
#   cd /usr/x86_64-alpine-linux-musl/bin
#   mv ld ld-o
#   echo -e '#!/bin/sh\n/usr/x86_64-alpine-linux-musl/bin/ld-o --verbose $@ | tee -a /tmp/ldlog' > ld
#   chmod +x ld
#   mkdir -p /tmp/src/nginx/objs/
#   echo -e "#include <sys/types.h>\nint main(void) {\n;\n\nreturn 0;\n}\n" > /tmp/src/nginx/objs/autotest.c
#EOF
