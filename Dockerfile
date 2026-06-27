FROM michaelf34/infinity:latest-cpu

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

EXPOSE 8080

ENTRYPOINT ["/app/start.sh"]
