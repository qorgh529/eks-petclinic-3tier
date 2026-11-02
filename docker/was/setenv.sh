#!/bin/sh
# Sourced by catalina.sh on startup.
# - JAVA_OPTS (heap etc.) is read by catalina.sh itself.
# - SPRING_PROFILES_ACTIVE and JDBC_URL / JDBC_USERNAME / JDBC_PASSWORD are read by Spring
#   from the environment directly, so the password never appears on the java command line.

CATALINA_OPTS="${CATALINA_OPTS:-} -javaagent:/opt/jmx/jmx_prometheus_javaagent.jar=9404:/opt/jmx/config.yaml"

# Spring's relaxed binding cannot map JDBC_DRIVER_CLASS_NAME to jdbc.driverClassName.
if [ -n "${JDBC_DRIVER_CLASS_NAME:-}" ]; then
  CATALINA_OPTS="$CATALINA_OPTS -Djdbc.driverClassName=$JDBC_DRIVER_CLASS_NAME"
fi

export CATALINA_OPTS

# Phase 1 of the move to /was: the Host's RewriteValve reads conf/Catalina/localhost/rewrite.config, and
# conf/Catalina is an emptyDir in k8s (writable under readOnlyRootFilesystem), which hides anything the
# image puts there. Removed in phase 2 with the valve.
mkdir -p "$CATALINA_BASE/conf/Catalina/localhost"
cp /opt/petclinic/rewrite.config "$CATALINA_BASE/conf/Catalina/localhost/rewrite.config"
