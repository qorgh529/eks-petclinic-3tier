# Build context: repository root
#   docker build -f docker/was/Dockerfile -t was:<tag> .

# ---- Stage 1: build the WAR (MySQL profile, credentials injected at runtime) ----
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY app/pom.xml .
COPY app/src ./src
# Tests run against H2 outside the image build (./mvnw test); -P MySQL disables the H2 profile.
# Unpacked here so Tomcat never writes to webapps/ (allows readOnlyRootFilesystem).
# Deployed as webapps/was: the app lives under /was/, and web Nginx serves / itself.
RUN mvn -B -P MySQL -DskipTests package \
 && mkdir /was && cd /was && jar xf /src/target/petclinic.war

ARG JMX_EXPORTER_VERSION=1.0.1
ARG JMX_EXPORTER_SHA256=7d61f737fd661610ccc14aea79764faa1ea94a340cbc8f0029b3d2edea3d80c1
RUN mvn -B -q dependency:copy \
      -Dartifact=io.prometheus.jmx:jmx_prometheus_javaagent:${JMX_EXPORTER_VERSION} \
      -DoutputDirectory=/tmp/jmx \
 && mv /tmp/jmx/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar /jmx_prometheus_javaagent.jar \
 && echo "${JMX_EXPORTER_SHA256}  /jmx_prometheus_javaagent.jar" | sha256sum -c -

# ---- Stage 2: Tomcat 11 runtime (no Maven / sources) ----
FROM tomcat:11.0.2-jre21-temurin-noble
WORKDIR /usr/local/tomcat

RUN rm -rf webapps/* webapps.dist \
 && groupadd -g 10001 app \
 && useradd -u 10001 -g app -M -s /usr/sbin/nologin app \
 && mkdir -p conf/Catalina/localhost

COPY --from=build /was webapps/was
COPY --from=build /jmx_prometheus_javaagent.jar /opt/jmx/jmx_prometheus_javaagent.jar
COPY docker/was/jmx-exporter-config.yaml /opt/jmx/config.yaml
COPY docker/was/setenv.sh bin/setenv.sh
COPY docker/was/server.xml conf/server.xml
# conf/Catalina is an emptyDir in k8s, so setenv.sh copies this into place at start.
COPY docker/was/rewrite.config /opt/petclinic/rewrite.config

# Tomcat writes only runtime state (mounted as emptyDir in k8s; owned by 10001 for plain docker run).
RUN chmod 0755 bin/setenv.sh \
 && chown -R 10001:10001 work temp logs conf/Catalina

USER 10001
EXPOSE 8080 9404
CMD ["catalina.sh", "run"]
