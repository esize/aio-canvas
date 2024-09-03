FROM ruby:3.3

ARG REVISION=master
ENV RAILS_ENV=development
ENV GEM_HOME=/opt/canvas/.gems
ENV GEM_PATH=/opt/canvas/.gems:/opt/canvas/.gem/ruby/3.3.0
ENV PATH=/opt/canvas/.local/share/gem/ruby/3.3.0/bin:$PATH
ENV DEBIAN_FRONTEND=noninteractive
ENV YARN_VERSION=1.19.1-1

# add nodejs and recommended ruby repos
RUN apt-get update
RUN apt-get install -y supervisor redis-server sudo \
        zlib1g-dev libxml2-dev libxslt1-dev libsqlite3-dev postgresql \
        postgresql-contrib libpq-dev libxmlsec1-dev curl make g++ git \
        unzip fontforge libicu-dev libidn-dev

RUN curl -sL https://deb.nodesource.com/setup_18.x | bash \
    && curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs \
        yarn \
        unzip \
        fontforge

RUN apt-get clean && rm -Rf /var/cache/apt

# Set the locale to avoid active_model_serializers bundler install failure
RUN sudo locale-gen "en_US.UTF-8"
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
RUN sudo dpkg-reconfigure locales

RUN groupadd -r canvasuser -g 433 && \
    adduser --uid 431 --system --gid 433 --home /opt/canvas canvasuser && \
    adduser canvasuser sudo && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL\nDefaults env_keep += "GEM_HOME RAILS_ENV REVISION LANG LANGUAGE LC_ALL"' >> /etc/sudoers

RUN sudo -u canvasuser mkdir -p $GEM_HOME \
  && sudo -u canvasuser gem install --user-install bundler:2.2.19 --no-document

COPY --chown=canvasuser assets/dbinit.sh /opt/canvas/dbinit.sh
COPY --chown=canvasuser assets/start.sh /opt/canvas/start.sh
RUN chmod 755 /opt/canvas/*.sh

COPY assets/supervisord.conf /etc/supervisor/supervisord.conf
COPY assets/pg_hba.conf /etc/postgresql/15/main/pg_hba.conf

RUN sed -i "/^#listen_addresses/i listen_addresses='*'" /etc/postgresql/15/main/postgresql.conf

RUN cd /opt/canvas \
    && git clone https://github.com/instructure/canvas-lms.git --depth 1 --single-branch \
    && cd canvas-lms \
    && git checkout $REVISION

WORKDIR /opt/canvas/canvas-lms

COPY --chown=canvasuser assets/database.yml config/database.yml
COPY --chown=canvasuser assets/redis.yml config/redis.yml
COPY --chown=canvasuser assets/cache_store.yml config/cache_store.yml
COPY --chown=canvasuser assets/development-local.rb config/environments/development-local.rb
COPY --chown=canvasuser assets/outgoing_mail.yml config/outgoing_mail.yml
COPY assets/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN for config in amazon_s3 delayed_jobs domain file_store security external_migration \
       ; do cp config/$config.yml.example config/$config.yml \
       ; done

RUN bundle install --jobs 8 --without="mysql"
RUN yarn config set workspaces-experimental true
RUN yarn install --pure-lockfile
RUN COMPILE_ASSETS_NPM_INSTALL=0 $GEM_HOME/bin/bundle exec rake canvas:compile_assets_dev

RUN mkdir -p log tmp/pids public/assets public/stylesheets/compiled \
    && touch Gemmfile.lock

RUN service postgresql start && /opt/canvas/dbinit.sh

RUN chown -R canvasuser: /opt/canvas
RUN chown -R canvasuser: /tmp/attachment_fu/

# postgres
EXPOSE 5432
# redis
EXPOSE 6379
# canvas
EXPOSE 3000

HEALTHCHECK --interval=3m --start-period=5m \
   CMD /usr/local/bin/healthcheck.sh

CMD ["/opt/canvas/start.sh"]
