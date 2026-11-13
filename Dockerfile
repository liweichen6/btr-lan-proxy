# Build a native executable, then ship it with only the libraries it needs.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/btr_lan_proxy.dart -o /app/btr-lan-proxy

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/btr-lan-proxy /btr-lan-proxy
EXPOSE 8080
ENTRYPOINT ["/btr-lan-proxy"]
