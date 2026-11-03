# Общий образ для invest-api и invest-gateway.
# Контекст сборки - app/target/dockerbuild сервиса (раскладку делает `mvn package`), сертификаты - отдельный build context:
#   docker build -f docker/java.Dockerfile --build-context certs=certs --build-arg MAIN_CLASS=... <repo>/app/target/dockerbuild
FROM eclipse-temurin:25-jre-alpine

# Корневой сертификат Минцифры: им подписан сертификат invest-public-api.tinkoff.ru
COPY --from=certs russian_trusted_root_ca.pem /tmp/russian_trusted_root_ca.pem
RUN keytool -importcert -noprompt -cacerts -storepass changeit \
      -alias russian_trusted_root_ca -file /tmp/russian_trusted_root_ca.pem \
    && rm /tmp/russian_trusted_root_ca.pem

# числовой UID: иначе kubelet не может проверить runAsNonRoot
RUN addgroup -S -g 1000 app && adduser -S -u 1000 -G app app
WORKDIR /app
USER 1000

#   ext - сторонние библиотеки: меняются редко, слой берётся из кэша
#   lib - модули проекта: меняются почти в каждой сборке
COPY ext/ ext/
COPY lib/ lib/

# ARG после COPY: слои выше общие для обоих сервисов
ARG MAIN_CLASS
ENV MAIN_CLASS=${MAIN_CLASS}
EXPOSE 8080

# конфиг монтируется из ConfigMap в /app/config (Spring читает ./config/application*.yml)
ENTRYPOINT ["sh", "-c", "exec java -XX:MaxRAMPercentage=75.0 -cp '/app/lib/*:/app/ext/*' \"$MAIN_CLASS\""]
