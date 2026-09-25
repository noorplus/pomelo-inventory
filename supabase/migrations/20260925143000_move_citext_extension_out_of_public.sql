-- Keep third-party extensions outside the exposed public schema.
create schema if not exists extensions;
alter extension citext set schema extensions;
