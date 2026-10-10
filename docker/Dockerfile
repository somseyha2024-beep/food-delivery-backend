# Build from repo root:  docker build -f docker/Dockerfile --build-arg SERVICE=auth-service .
FROM dart:stable AS build
ARG SERVICE
WORKDIR /app
COPY packages/common packages/common
COPY services/${SERVICE} services/${SERVICE}
WORKDIR /app/services/${SERVICE}
RUN dart pub get && dart compile exe bin/server.dart -o /app/server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/server /app/server
ENV PORT=8080
EXPOSE 8080
CMD ["/app/server"]
