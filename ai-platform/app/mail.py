from __future__ import annotations

import smtplib
import ssl
from dataclasses import dataclass
from email.message import EmailMessage

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import SystemSetting


SMTP_SETTING_KEYS = {
    "smtp_enabled",
    "smtp_host",
    "smtp_port",
    "smtp_security",
    "smtp_username",
    "smtp_password",
    "smtp_from_email",
    "smtp_from_name",
}


@dataclass(frozen=True)
class SMTPConfiguration:
    enabled: bool = False
    host: str = ""
    port: int = 587
    security: str = "starttls"
    username: str = ""
    password: str = ""
    from_email: str = ""
    from_name: str = "AI Platform"

    @property
    def ready(self) -> bool:
        return self.enabled and bool(self.host and self.from_email)


def smtp_configuration(db: Session) -> SMTPConfiguration:
    rows = db.scalars(select(SystemSetting).where(SystemSetting.key.in_(SMTP_SETTING_KEYS))).all()
    values = {row.key: row.value for row in rows}
    try:
        port = int(values.get("smtp_port", 587))
    except (TypeError, ValueError):
        port = 587
    return SMTPConfiguration(
        enabled=bool(values.get("smtp_enabled", False)),
        host=str(values.get("smtp_host", "")),
        port=port,
        security=str(values.get("smtp_security", "starttls")),
        username=str(values.get("smtp_username", "")),
        password=str(values.get("smtp_password", "")),
        from_email=str(values.get("smtp_from_email", "")),
        from_name=str(values.get("smtp_from_name", "AI Platform")),
    )


def send_email(configuration: SMTPConfiguration, recipient: str, subject: str, text_body: str) -> None:
    if not configuration.ready:
        raise RuntimeError("SMTP is not fully configured")
    if configuration.security not in {"none", "starttls", "ssl"}:
        raise RuntimeError("SMTP security mode is invalid")

    message = EmailMessage()
    message["From"] = f"{configuration.from_name} <{configuration.from_email}>"
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(text_body)

    context = ssl.create_default_context()
    client_type = smtplib.SMTP_SSL if configuration.security == "ssl" else smtplib.SMTP
    keyword_arguments = {"host": configuration.host, "port": configuration.port, "timeout": 15}
    if configuration.security == "ssl":
        keyword_arguments["context"] = context
    with client_type(**keyword_arguments) as client:
        client.ehlo()
        if configuration.security == "starttls":
            client.starttls(context=context)
            client.ehlo()
        if configuration.username:
            client.login(configuration.username, configuration.password)
        client.send_message(message)
