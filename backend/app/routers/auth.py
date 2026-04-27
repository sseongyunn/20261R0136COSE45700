from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database import get_db
from app.security import create_access_token, hash_password, verify_password


router = APIRouter(prefix="/auth", tags=["auth"])


class AuthRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)


class AuthUser(BaseModel):
    id: str
    email: EmailStr


class AuthResponse(BaseModel):
    accessToken: str
    tokenType: str = "bearer"
    user: AuthUser


def _auth_response(user_id: object, email: str) -> AuthResponse:
    return AuthResponse(
        accessToken=create_access_token(user_id, email),
        user=AuthUser(id=str(user_id), email=email),
    )


@router.post("/signup", response_model=AuthResponse)
def signup(payload: AuthRequest, db: Session = Depends(get_db)) -> AuthResponse:
    email = payload.email.lower().strip()
    password_hash = hash_password(payload.password)

    try:
        user_row = db.execute(
            text("INSERT INTO users (email) VALUES (:email) RETURNING id, email"),
            {"email": email},
        ).mappings().one()
        db.execute(
            text(
                """
                INSERT INTO user_identities (user_id, provider, provider_user_id, password_hash)
                VALUES (:user_id, 'local', :email, :password_hash)
                """
            ),
            {"user_id": str(user_row["id"]), "email": email, "password_hash": password_hash},
        )
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email is already registered",
        ) from exc

    return _auth_response(user_row["id"], user_row["email"])


@router.post("/login", response_model=AuthResponse)
def login(payload: AuthRequest, db: Session = Depends(get_db)) -> AuthResponse:
    email = payload.email.lower().strip()
    row = db.execute(
        text(
            """
            SELECT u.id, u.email, ui.password_hash
            FROM users u
            JOIN user_identities ui ON ui.user_id = u.id
            WHERE ui.provider = 'local' AND ui.provider_user_id = :email
            """
        ),
        {"email": email},
    ).mappings().first()

    if row is None or row["password_hash"] is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    if not verify_password(payload.password, row["password_hash"]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    return _auth_response(row["id"], row["email"])
