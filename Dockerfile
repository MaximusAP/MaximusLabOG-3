FROM nginx:1.29-alpine

# curl is required for the Docker HEALTHCHECK.
RUN apk add --no-cache curl \
    && rm -rf /usr/share/nginx/html/* \
    && rm -f /etc/nginx/conf.d/default.conf

COPY index.html hero.jpeg pipeline.jpeg /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl --fail --silent http://localhost/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
