# Development, test and benchmark container for the opcache dedup patches.
# Every php-src series is built inside the container (see docker/build.sh);
# nothing is installed on the Docker host itself.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
	autoconf bison build-essential ca-certificates curl gdb git libfcgi-bin \
	perl pkg-config procps re2c rsync time unzip valgrind \
	libonig-dev libssl-dev libxml2-dev zlib1g-dev \
	mariadb-server mariadb-client nginx-light nghttp2-client \
 && rm -rf /var/lib/apt/lists/*

ENV REPO=/repo BUILD=/build
WORKDIR /repo
CMD ["sleep", "infinity"]
