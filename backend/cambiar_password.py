"""Cambia la contraseña de un usuario de la aplicación.

Uso (con el entorno virtual activado, dentro de la carpeta backend):
    python cambiar_password.py
Te pide el correo y la contraseña nueva (no se muestra al teclear).
"""
import getpass

import bcrypt
from dotenv import load_dotenv

load_dotenv()
import db  # noqa: E402


def main():
    correo = input("Correo del usuario: ").strip().lower()
    if not correo:
        return print("Debes escribir un correo.")

    nueva = getpass.getpass("Contraseña nueva (mínimo 8 caracteres): ")
    if len(nueva) < 8 or len(nueva.encode()) > 72:
        return print("La contraseña debe tener entre 8 y 72 caracteres.")
    if nueva != getpass.getpass("Repite la contraseña nueva: "):
        return print("Las contraseñas no coinciden. No se cambió nada.")

    hash_nuevo = bcrypt.hashpw(nueva.encode(), bcrypt.gensalt()).decode()

    db.init_pool()
    # Se usa el rol Administrador (es quien tiene permiso de modificar usuarios);
    # el cambio queda registrado en la bitácora como proceso del sistema.
    with db.transaccion({"id_usuario": None, "rol": "Administrador"}, "consola") as cur:
        cur.execute(
            "UPDATE usuario SET hash_password = %s WHERE lower(correo) = %s",
            (hash_nuevo, correo),
        )
        if cur.rowcount == 0:
            return print(f"No existe ningún usuario con el correo {correo}.")
    print(f"Contraseña de {correo} actualizada.")


if __name__ == "__main__":
    main()
