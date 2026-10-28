# syntax=docker/dockerfile:1
# 构建阶段固定在构建机本机架构，用 Go 交叉编译目标架构，多平台镜像不需要 QEMU 模拟。
FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src/services/receiver
COPY services/receiver/go.mod services/receiver/go.sum ./
RUN go mod download
COPY services/receiver/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/nowbeam-receiver ./cmd/nowbeam-receiver \
    && sh scripts/collect-licenses.sh /out/licenses \
    && mkdir -p /out/data \
    && chmod 0700 /out/data

FROM scratch
COPY --from=build /out/nowbeam-receiver /nowbeam-receiver
COPY --from=build /out/licenses /licenses
COPY --from=build --chown=65532:65532 --chmod=0700 /out/data/ /var/lib/nowbeam/
USER 65532:65532
ENV NOWBEAM_DATABASE_PATH=/var/lib/nowbeam/nowbeam.sqlite
EXPOSE 8787
ENTRYPOINT ["/nowbeam-receiver"]
