FROM debian:13

# Install necessary packages and locales
RUN apt-get update && apt-get install -y \
    postgresql-common \
    curl \
    ca-certificates \
    locales

# Generate en_US.UTF-8 locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=en_US.UTF-8

# Set environment variables for locale
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

RUN apt-get update && apt-get install -y \
    postgresql-12 \
    postgresql-13 \
    postgresql-14 \
    postgresql-15 \
    postgresql-16 \
    postgresql-17 \
    postgresql-18 \
    postgresql-client-12 \
    postgresql-client-13 \
    postgresql-client-14 \
    postgresql-client-15 \
    postgresql-client-16 \
    postgresql-client-17 \
    postgresql-client-18
    # && rm -rf /var/lib/apt/lists/*

# Copy the upgrade script
COPY upgrade.sh /usr/local/bin/upgrade.sh
RUN chmod +x /usr/local/bin/upgrade.sh

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/upgrade.sh"]
# keep the container running
# ENTRYPOINT ["while true; do sleep 3600; done"]
