# Drupal CMS 2.2.10 (Drupal core 11.4.13) for Railway, built from the pinned
# composer.lock in site/ on the official Drupal image (PHP 8.4, Apache). The
# code is fixed in the image and owned by root; uploads, private files and the
# configuration sync directory live on the volume mounted at /var/lib/drupal.
# The install runs in scripts/drupal-start.sh before Apache opens port 80.
FROM drupal:11.4.13-php8.4-apache-trixie@sha256:60a02ee14c147aad32025da047d16c2251331788e0d912ce23029138d0ad6e85 AS build
WORKDIR /opt/drupal-cms
COPY site/composer.json site/composer.lock site/LICENSE.txt ./
RUN COMPOSER_HOME=/tmp/composer composer install --no-dev --no-interaction --no-progress --optimize-autoloader \
  && rm -rf /tmp/composer
# Custom modules and themes (empty in the template) go with the code.
COPY site/web/modules/custom web/modules/custom
COPY site/web/themes/custom web/themes/custom

FROM drupal:11.4.13-php8.4-apache-trixie@sha256:60a02ee14c147aad32025da047d16c2251331788e0d912ce23029138d0ad6e85
# The base image's own Drupal core project in /opt/drupal is left in place but
# unused: deleting it would add whiteouts, which Railway's runtime has been
# seen to ignore. The web root symlink points at Drupal CMS instead.
COPY --from=build /opt/drupal-cms /opt/drupal-cms
COPY config/settings.php /opt/drupal-cms/web/sites/default/settings.php
COPY config/apache-railway.conf /etc/apache2/conf-enabled/zz-railway-client-address.conf
COPY config/php-railway.ini /usr/local/etc/php/conf.d/zz-railway.ini
COPY scripts/drupal-db.php scripts/drupal-provision.php /usr/local/lib/drupal-template/
COPY scripts/drupal-start.sh /usr/local/bin/drupal-start
RUN set -eux; \
  cp "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"; \
  a2enmod headers; \
  ln -sfn /opt/drupal-cms/web /var/www/html; \
  ln -s /var/lib/drupal/files /opt/drupal-cms/web/sites/default/files; \
  chmod 0444 /opt/drupal-cms/web/sites/default/settings.php; \
  chmod 0755 /usr/local/bin/drupal-start; \
  chmod 0644 /usr/local/lib/drupal-template/*.php; \
  chown -R root:root /opt/drupal-cms; \
  mkdir -p /var/lib/drupal
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/drupal-cms/vendor/bin
WORKDIR /opt/drupal-cms
EXPOSE 80
# The base image stops with SIGWINCH (Apache's graceful stop, which can wait
# for slow clients indefinitely); drupal-start handles SIGTERM and stops Apache.
STOPSIGNAL SIGTERM
CMD ["/usr/local/bin/drupal-start"]
