from __future__ import annotations

from typing import Any


SUPPORTED_LANGUAGES = {"en", "es"}
DEFAULT_LANGUAGE = "en"

SERVER_TRANSLATIONS = {
    "es": {
        "Reset your {brand_name} password": "Restablece tu contraseña de {brand_name}",
        "A password reset was requested for your account.\n\nOpen this link within 30 minutes:\n{url}\n\nIf you did not request this, you can ignore this email.": (
            "Se solicitó restablecer la contraseña de tu cuenta.\n\n"
            "Abre este enlace dentro de los próximos 30 minutos:\n{url}\n\n"
            "Si no realizaste esta solicitud, puedes ignorar este correo."
        ),
        "{brand_name} SMTP test": "Prueba SMTP de {brand_name}",
        "SMTP is configured correctly. Password reset emails can now be delivered.": (
            "SMTP está configurado correctamente. Ya se pueden enviar correos para restablecer contraseñas."
        ),
    }
}


def normalize_language(value: Any, default: str = DEFAULT_LANGUAGE) -> str:
    language = str(value or "").strip().lower().replace("_", "-").split("-", 1)[0]
    return language if language in SUPPORTED_LANGUAGES else default


def translate(language: str, message: str, **values: Any) -> str:
    translated = SERVER_TRANSLATIONS.get(normalize_language(language), {}).get(message, message)
    return translated.format(**values)
