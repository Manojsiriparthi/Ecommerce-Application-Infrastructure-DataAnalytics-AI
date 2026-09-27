-- =============================================================================
-- CI Postgres initialisation
-- Creates one database per microservice, all owned by the CI user.
-- Prisma migrations run inside each service container at startup and
-- create the tables automatically — no manual schema needed here.
-- =============================================================================
CREATE DATABASE user_db;
CREATE DATABASE product_db;
CREATE DATABASE cart_db;
CREATE DATABASE order_db;
CREATE DATABASE payment_db;

-- notification-service has no database
