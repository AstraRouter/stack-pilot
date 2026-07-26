#!/usr/bin/env bash

install_certbot() {
  if command_exists certbot; then
    ok "Certbot is already installed"
    install_certbot_renew_job
    return 0
  fi

  detect_os
  case "${PM}" in
    apt-get)
      install_packages snapd
      systemctl enable --now snapd >/dev/null 2>&1 || true
      snap install core || true
      snap refresh core || true
      snap install --classic certbot
      ln -sf /snap/bin/certbot /usr/bin/certbot
      ;;
    dnf|yum)
      # Amazon Linux 2023 has no EPEL but ships certbot in its base repositories.
      install_packages epel-release || true
      install_packages certbot
      ;;
    zypper)
      install_packages certbot
      ;;
    *)
      die "Certbot could not be installed automatically for package manager '${PM:-unknown}'; see https://certbot.eff.org/"
      ;;
  esac
  command_exists certbot ||
    die "Certbot installation completed without producing a certbot binary; see https://certbot.eff.org/"
  install_certbot_renew_job
}

LNMP_CERTBOT_CRON_MARKER="# stack-pilot-certbot-renew"

install_certbot_renew_job() {
  if command_exists systemctl; then
    cat > /etc/systemd/system/lnmp-certbot-renew.service <<'EOF'
[Unit]
Description=Renew Let's Encrypt certificates for LNMP installer

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --deploy-hook "systemctl reload nginx"
EOF
    cat > /etc/systemd/system/lnmp-certbot-renew.timer <<'EOF'
[Unit]
Description=Twice daily Let's Encrypt renewal check

[Timer]
OnCalendar=*-*-* 03,15:20:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now lnmp-certbot-renew.timer >/dev/null 2>&1 || true
  else
    # The marker lets the uninstaller remove exactly this line instead of every
    # crontab entry that happens to mention "certbot renew".
    (crontab -l 2>/dev/null | grep -v "${LNMP_CERTBOT_CRON_MARKER}"; \
     printf '20 3,15 * * * /usr/bin/certbot renew --deploy-hook "service nginx reload" >/dev/null 2>&1 %s\n' "${LNMP_CERTBOT_CRON_MARKER}") | crontab -
  fi
}
