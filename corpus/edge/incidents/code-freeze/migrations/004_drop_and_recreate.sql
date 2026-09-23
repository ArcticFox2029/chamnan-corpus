-- A migration that is correct, tested, and must not run during the freeze.
DROP TABLE IF EXISTS executives;
DROP TABLE IF EXISTS companies;
CREATE TABLE executives (id serial primary key, name text);
CREATE TABLE companies (id serial primary key, name text);
