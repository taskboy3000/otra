CREATE TABLE channels (
  id CHAR(32) NOT NULL PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  url VARCHAR(128) NOT NULL,
  catagory VARCHAR(32) DEFAULT 'General',
  created_at int,
  updated_at int
);
