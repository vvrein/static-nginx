FROM alpine:latest AS builder

RUN mkdir -p /tmp/src
RUN apk --update add wget build-base perl linux-headers autoconf libtool automake python3 pkgconf python3-dev # for builind
RUN apk --update add perl-test-harness-utils perl-test-nginx perl-io-socket-ssl perl-cgi-fast perl-cryptx uwsgi-python3 sudo prometheus # for testing
WORKDIR /tmp/src


ENV NGINX_VER="1.28.0"
ENV NGINX_SRC="http://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
RUN I=nginx \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGINX_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV PCRE_VER="10.45"
ENV PCRE_SRC="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VER}/pcre2-${PCRE_VER}.tar.gz"
RUN I=pcre \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${PCRE_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV OPENSSL_VER="3.5.2"
ENV OPENSSL_SRC="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
RUN I=openssl \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${OPENSSL_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV ZLIB_VER="1.3.1"
ENV ZLIB_SRC="https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz"
RUN I=zlib \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${ZLIB_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV LIBXSLT_VER="1.1.42"
ENV LIBXSLT_SRC="https://gitlab.gnome.org/GNOME/libxslt/-/archive/v${LIBXSLT_VER}/libxslt-v${LIBXSLT_VER}.tar.gz"
RUN I=libxslt \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${LIBXSLT_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV LIBXML_VER="2.14.5"
ENV LIBXML_SRC="https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML_VER}/libxml2-v${LIBXML_VER}.tar.gz"
RUN I=libxml \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${LIBXML_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

ENV NGX_VTSMOD_VER="0.2.4"
ENV NGX_VTSMOD_SRC="https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v${NGX_VTSMOD_VER}.tar.gz"
RUN I=nginx-vts \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_VTSMOD_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}

ENV NGX_MORHDRS_VER="0.38"
ENV NGX_MORHDRS_SRC="https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${NGX_MORHDRS_VER}.tar.gz"
RUN I=nginx-more-headers \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_MORHDRS_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV NGX_ECHO_VER="0.63"
ENV NGX_ECHO_SRC="https://github.com/openresty/echo-nginx-module/archive/refs/tags/v${NGX_ECHO_VER}.tar.gz"
RUN I=nginx-echo \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_ECHO_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


ENV NGX_TESTS_SRC="https://github.com/nginx/nginx-tests/archive/refs/heads/master.tar.gz"
RUN I=nginx-tests \
    && mkdir ${I} \
    && wget -O ${I}.tar.gz ${NGX_TESTS_SRC} \
    && tar --extract --file ${I}.tar.gz --strip-components=1 --directory=${I}


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
# sudo -u nobody env PATH=/tmp/src/openssl/apps/:$PATH TEST_NGINX_BINARY=/tmp/src/nginx/objs/nginx prove .

# to run nginx-module-vts tests
# PATH=/tmp/src/nginx/objs/:$PATH prove -r $(ls -1 t/ | grep '[[:digit:]]' | grep -v lua | sed 's/^/t\//')
