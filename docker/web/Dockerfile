# Build context: repository root
#   docker build -f docker/web/Dockerfile -t web:<tag> .

# ---- Stage 1: extract webjars (bootstrap, font-awesome, flatpickr) from the app's pom ----
FROM maven:3.9.9-eclipse-temurin-21 AS assets
WORKDIR /src
COPY app/pom.xml .
RUN mvn -B -q dependency:copy-dependencies \
      -DincludeGroupIds=org.webjars,org.webjars.npm \
      -DexcludeTransitive=true \
      -DoutputDirectory=/tmp/jars \
 && mkdir -p /static/webjars /tmp/x && cd /tmp/x \
 && for j in /tmp/jars/*.jar; do jar xf "$j" META-INF/resources/webjars; done \
 && cp -r META-INF/resources/webjars/. /static/webjars/
COPY app/src/main/webapp/resources /static/resources

# ---- Stage 2: Nginx, non-root on :8080 ----
FROM nginx:1.27.2-alpine

# Run unprivileged: drop the `user` directive, move pid file, let uid 10001 own runtime dirs.
RUN sed -i -e '/^user /d' -e 's#/var/run/nginx.pid#/tmp/nginx.pid#' /etc/nginx/nginx.conf \
 && rm -f /etc/nginx/conf.d/default.conf \
 && chown -R 10001:10001 /var/cache/nginx /etc/nginx/conf.d

COPY --from=assets /static /usr/share/nginx/html
# Public landing page, 404 page and their stylesheet (docs/features/landing-page/design.md).
COPY docker/web/static /usr/share/nginx/html
# Rendered to /etc/nginx/conf.d/default.conf by the image entrypoint (envsubst of defined env vars only).
COPY docker/web/nginx.conf /etc/nginx/templates/default.conf.template

ENV WAS_UPSTREAM_HOST=was \
    WAS_UPSTREAM_PORT=8080

USER 10001
EXPOSE 8080
