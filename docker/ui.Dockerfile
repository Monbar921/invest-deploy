# Статика invest-api-ui. Контекст сборки - собранный dist/, конфиг nginx - отдельный build context:
#   docker build -f docker/ui.Dockerfile --build-context conf=docker <invest-api-ui>/dist
FROM nginxinc/nginx-unprivileged:1.28-alpine

COPY --from=conf nginx.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html/
