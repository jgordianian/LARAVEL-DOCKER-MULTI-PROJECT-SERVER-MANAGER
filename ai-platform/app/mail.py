from __future__ import annotations

import smtplib
import ssl
from dataclasses import dataclass
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape
from sqlalchemy import select
from sqlalchemy.orm import Session

from .i18n import normalize_language, translate
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
MAIL_TEMPLATE_ROOT = Path(__file__).resolve().parent / "templates" / "mail"
mail_templates = Environment(
    loader=FileSystemLoader(str(MAIL_TEMPLATE_ROOT)),
    autoescape=select_autoescape(enabled_extensions=("html",)),
)


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


@dataclass(frozen=True)
class EmailBranding:
    brand_name: str = "AI Platform"
    logo_url: str = ""
    footer_text: str = "AI Platform"


@dataclass(frozen=True)
class EmailContent:
    subject: str
    text_body: str
    html_body: str


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


def _render_branded_html(
    branding: EmailBranding,
    language: str,
    *,
    preheader: str,
    eyebrow: str,
    title: str,
    introduction: str,
    action_label: str = "",
    action_url: str = "",
    supporting_paragraphs: tuple[str, ...] = (),
    details: tuple[tuple[str, str], ...] = (),
    raw_url_label: str = "",
) -> str:
    template = mail_templates.get_template("branded.html")
    return template.render(
        language=normalize_language(language),
        branding=branding,
        preheader=preheader,
        eyebrow=eyebrow,
        title=title,
        introduction=introduction,
        action_label=action_label,
        action_url=action_url,
        supporting_paragraphs=supporting_paragraphs,
        details=details,
        raw_url_label=raw_url_label,
        automated_notice=translate(language, "This is an automated message. Please do not reply to this email."),
    )


def password_reset_email(branding: EmailBranding, language: str, reset_url: str, expires_minutes: int = 30) -> EmailContent:
    subject = translate(language, "Reset your {brand_name} password", brand_name=branding.brand_name)
    introduction = translate(
        language,
        "We received a request to reset your account password for {brand_name}.",
        brand_name=branding.brand_name,
    )
    expiry = translate(language, "This secure link expires in {minutes} minutes.", minutes=expires_minutes)
    ignore = translate(language, "If you did not request this change, you can safely ignore this email.")
    raw_url_label = translate(language, "If the button does not work, copy and paste this link into your browser:")
    text_body = translate(
        language,
        "A password reset was requested for your account.\n\nOpen this link within {minutes} minutes:\n{url}\n\nIf you did not request this, you can ignore this email.",
        minutes=expires_minutes,
        url=reset_url,
    )
    return EmailContent(
        subject=subject,
        text_body=text_body,
        html_body=_render_branded_html(
            branding,
            language,
            preheader=subject,
            eyebrow=translate(language, "Account security"),
            title=translate(language, "Reset password"),
            introduction=introduction,
            action_label=translate(language, "Reset password"),
            action_url=reset_url,
            supporting_paragraphs=(expiry, ignore),
            raw_url_label=raw_url_label,
        ),
    )


def smtp_test_email(branding: EmailBranding, language: str, recipient: str) -> EmailContent:
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    subject = translate(language, "{brand_name} SMTP test", brand_name=branding.brand_name)
    introduction = translate(language, "SMTP is configured correctly. Password reset emails can now be delivered.")
    details = (
        (translate(language, "Channel"), translate(language, "Email")),
        (translate(language, "Status"), translate(language, "Configuration verified")),
        (translate(language, "Recipient"), recipient),
        (translate(language, "Generated at"), generated_at),
    )
    text_details = "\n".join(f"{label}: {value}" for label, value in details)
    return EmailContent(
        subject=subject,
        text_body=f"{introduction}\n\n{text_details}",
        html_body=_render_branded_html(
            branding,
            language,
            preheader=subject,
            eyebrow=translate(language, "Email delivery"),
            title=translate(language, "SMTP test successful"),
            introduction=introduction,
            details=details,
        ),
    )


def send_email(
    configuration: SMTPConfiguration,
    recipient: str,
    subject: str,
    text_body: str,
    html_body: str | None = None,
) -> None:
    if not configuration.ready:
        raise RuntimeError("SMTP is not fully configured")
    if configuration.security not in {"none", "starttls", "ssl"}:
        raise RuntimeError("SMTP security mode is invalid")

    message = EmailMessage()
    message["From"] = f"{configuration.from_name} <{configuration.from_email}>"
    message["To"] = recipient
    message["Subject"] = subject
    message["Date"] = formatdate(localtime=False, usegmt=True)
    message_id_domain = configuration.from_email.rsplit("@", 1)[-1] if "@" in configuration.from_email else None
    message["Message-ID"] = make_msgid(domain=message_id_domain)
    message.set_content(text_body)
    if html_body:
        message.add_alternative(html_body, subtype="html")

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
