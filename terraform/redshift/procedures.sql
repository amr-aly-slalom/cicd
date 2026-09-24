-- Idempotent guard procedures for Redshift objects that lack IF NOT EXISTS.
CREATE OR REPLACE PROCEDURE sp_create_role_if_not_exists(p_role_name varchar)
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM SVV_ROLES WHERE role_name = p_role_name) THEN
    EXECUTE 'CREATE ROLE ' || quote_ident(p_role_name);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Idempotent database creation
CREATE OR REPLACE PROCEDURE sp_create_database_if_not_exists(db_name varchar)
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = db_name) THEN
    EXECUTE 'CREATE DATABASE ' || quote_ident(db_name);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Idempotent role-to-role grant
CREATE OR REPLACE PROCEDURE sp_grant_role_if_not_member(parent_role varchar, child_role varchar)
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM SVV_ROLE_GRANTS
    WHERE role_name = child_role AND granted_role_name = parent_role
  ) THEN
    EXECUTE 'GRANT ROLE ' || quote_ident(parent_role) || ' TO ROLE ' || quote_ident(child_role);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Idempotent database user creation.
CREATE OR REPLACE PROCEDURE sp_create_user_if_not_exists(user_name varchar, password_clause varchar)
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = user_name) THEN
    EXECUTE 'CREATE USER ' || quote_ident(user_name) || ' ' || password_clause;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Idempotent user-to-role grant (put a user into one of the tier roles).
CREATE OR REPLACE PROCEDURE sp_grant_role_to_user_if_not_member(p_role_name varchar, p_user_name varchar)
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM SVV_USER_GRANTS
    WHERE user_name = p_user_name AND role_name = p_role_name
  ) THEN
    EXECUTE 'GRANT ROLE ' || quote_ident(p_role_name) || ' TO ' || quote_ident(p_user_name);
  END IF;
END;
$$ LANGUAGE plpgsql;
