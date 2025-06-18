# Copyright (c) 2022-2025, AllWorldIT.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.


FROM registry.conarx.tech/containers/alpine/3.22 AS go-builder


# https://go.dev/dl/
ENV GO_VER=1.24.4


# Copy build patches
COPY patches build/patches


# Install libs we need
RUN set -eux; \
	true "Installing build dependencies"; \
# from https://git.alpinelinux.org/aports/tree/main/go/APKBUILD
	apk add --no-cache \
		build-base \
		binutils gcc musl-dev \
		go-bootstrap \
		bash binutils-gold git git-daemon


# Download packages
RUN set -eux; \
	mkdir -p build; \
	cd build; \
	wget "https://go.dev/dl/go$GO_VER.src.tar.gz"; \
	tar -xf "go${GO_VER}.src.tar.gz"


# Build and install Go
RUN set -eux; \
	cd build; \
	export srcdir=$PWD; \
	cd "go"; \
# Patching
	for i in ../patches/*.patch; do \
		echo "Applying patch $i..."; \
		patch -p1 < $i; \
	done; \
	\
	export builddir="$srcdir"/go; \
	mkdir -p "$builddir"; \
	export GOOS="linux"; \
	export GOPATH="$srcdir"; \
	export GOROOT="$builddir"; \
	export GOBIN="$GOROOT"/bin; \
	export GOROOT_FINAL="/opt/go-$GO_VER/lib"; \
	\
	cd src; \
	./make.bash -v; \
	find "$builddir"; \
# Test
	# Test suite does not pass with ccache, thus remove it form $PATH.
	export PATH="$(echo "$PATH" | sed 's|/usr/lib/ccache/bin:||g')"; \
	PATH="$builddir/bin:$PATH" ./run.bash -no-rebuild; \
# Install
	cd ..; \
	pkgdir="/opt/go-$GO_VER"; \
	mkdir -p "$pkgdir"/bin "$pkgdir"/lib/go/bin "$pkgdir"/share/doc/go; \
	\
	for binary in go gofmt; do \
		install -Dm755 bin/"$binary" "$pkgdir"/lib/go/bin/"$binary"; \
		ln -s "$pkgdir/lib/go/bin/$binary" "$pkgdir"/bin/; \
	done; \
	\
	cp -a misc pkg src lib "$pkgdir"/lib/go; \
	cp -r doc "$pkgdir"/share/doc/go; \
# Remove cruft
	rm -rfv "$pkgdir"/lib/go/pkg/obj; \
	rm -rfv "$pkgdir"/lib/go/pkg/bootstrap; \
	rm -fv  "$pkgdir"/lib/go/pkg/tool/*/api; \
	\
	# Install go.env, see https://go.dev/doc/toolchain#GOTOOLCHAIN.
	install -Dm644 "$builddir"/go.env "$pkgdir"/lib/go/go.env; \
	install -Dm644 VERSION "$pkgdir/lib/go/VERSION"; \
	\
	# Remove tests from /usr/lib/go/src to reduce package size,
	# these should not be needed at run-time by any program.
	find "$pkgdir"/lib/go/src \( -type f -a -name "*_test.go" \) \
		-exec rm -rfv \{\} \+; \
	find "$pkgdir"/lib/go/src \( -type d -a -name "testdata" \) \
		-exec rm -rfv \{\} \+; \
	# Remove rc (plan 9) and bat scripts (windows) to reduce package
	# size further. The bash scripts are actually needed at run-time.
	#
	# See: https://gitlab.alpinelinux.org/alpine/aports/issues/11091
	find "$pkgdir"/lib/go/src -type f -a \( -name "*.rc" -o -name "*.bat" \) \
		-exec rm -rf \{\} \+



RUN set -eux; \
	cd "/opt/go-$GO_VER"; \
	scanelf --recursive --nobanner --osabi --etype "ET_DYN,ET_EXEC" .  | awk '{print $3}' | xargs \
		strip \
			--remove-section=.comment \
			--remove-section=.note \
			-R .gnu.lto_* -R .gnu.debuglto_* \
			-N __gnu_lto_slim -N __gnu_lto_v1 \
			--strip-unneeded; \
	du -hs .


FROM registry.conarx.tech/containers/alpine/3.22

ARG VERSION_INFO=
LABEL org.opencontainers.image.authors		= "Nigel Kukard <nkukard@conarx.tech>"
LABEL org.opencontainers.image.version		= "3.22"
LABEL org.opencontainers.image.base.name	= "registry.conarx.tech/containers/alpine/3.22"

# https://go.dev/dl/
ENV GO_VER=1.24.4

ENV FDC_DISABLE_SUPERVISORD=true
ENV FDC_QUIET=true

# Copy in built binaries
COPY --from=go-builder /opt /opt/

# Install libs we need
RUN set -eux; \
	true "Installing build dependencies"; \
# from https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/community/go/APKBUILD
	apk add --no-cache \
		binutils gcc musl-dev

# Adjust flexible docker containers as this is not a daemon-based image
RUN set -eux; \
	ls -la /opt; \
	# Set up this language so it can be pulled into other images
	echo "# Go $GO_VER" > "/opt/go-$GO_VER/ld-musl-x86_64.path"; \
	echo "/opt/go-$GO_VER/lib" >> "/opt/go-$GO_VER/ld-musl-x86_64.path"; \
	echo "/opt/go-$GO_VER/bin" > "/opt/go-$GO_VER/PATH"; \
	# Set up library search path
	cat "/opt/go-$GO_VER/ld-musl-x86_64.path" >> /etc/ld-musl-x86_64.path; \
	# Remove things we dont need
	rm -f /usr/local/share/flexible-docker-containers/tests.d/40-crond.sh; \
	rm -f /usr/local/share/flexible-docker-containers/tests.d/90-healthcheck.sh

RUN set -eux; \
	true "Test"; \
# Test
	export PATH="$(cat /opt/go-*/PATH):$PATH"; \
	go version; \
	du -hs /opt/go-$GO_VER

# Go
COPY usr/local/share/flexible-docker-containers/init.d/41-go.sh /usr/local/share/flexible-docker-containers/init.d
COPY usr/local/share/flexible-docker-containers/tests.d/41-go.sh /usr/local/share/flexible-docker-containers/tests.d
RUN set -eux; \
	true "Flexible Docker Containers"; \
	if [ -n "$VERSION_INFO" ]; then echo "$VERSION_INFO" >> /.VERSION_INFO; fi; \
	true "Permissions"; \
	fdc set-perms
