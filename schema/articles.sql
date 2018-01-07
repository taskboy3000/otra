CREATE TABLE articles (
  id CHAR(32) NOT NULL PRIMARY KEY,
  channel_id CHAR(32) NOT NULL,
  url VARCHAR(255) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  published_at int,
  created_at int,
  updated_at int
);
