-- Allow new users to register:
-- * Each username has to be unique
-- * Usernames can be composed of at most 25 characters
-- * Usernames can’t be empty
-- * We won’t worry about user passwords for this project

-- DROP TABLES
DROP TABLE users, topics, posts, comments, votes;

-- CREATE TABLE TOPICS
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username CHARACTER VARYING(25) NOT NULL,
    time_created TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    username_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(username),
    CONSTRAINT "name_not_null" CHECK ("username" IS NOT NULL),
    CONSTRAINT "username_not_empty" CHECK (LENGTH(TRIM("username")) > 0);
);

CREATE INDEX "username_index" ON "users" ("username");

-- CREATE TRIGGER FUNCTION TO UPDATE TIME WHEN USER CHANGES USERNAME
CREATE OR REPLACE FUNCTION trigger_username_updated()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.username != OLD.username
  THEN
    NEW.username_updated := current_date;
  END IF;
  RETURN NEW;
END;
$$;

-- CREATE THE TRIGGER
CREATE TRIGGER trigger_username_updated
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE PROCEDURE trigger_username_updated();


-- Allow registered users to create new topics:
-- * Topic names have to be unique.
-- * The topic’s name is at most 30 characters
-- * The topic’s name can’t be empty
-- * Topics can have an optional description of at most 500 characters.

-- CREATE TABLE TOPICS
CREATE TABLE IF NOT EXISTS topics (
    id SERIAL PRIMARY KEY,
    topic_name CHARACTER VARYING(30) NOT NULL,
    topic_description CHARACTER VARYING(500) DEFAULT NULL,
    time_created TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(topic_name),
    CONSTRAINT "name_not_null" CHECK ("topic_name" IS NOT NULL)
    CONSTRAINT "name_not_empty" CHECK (LENGTH(TRIM("topic_name")) > 0);
);

-- CREATE UNIQUE INDEX "unique_topics" ON "topics" (TRIM("topic_name")); -- FOUND ONLINE TO CREATE A UNIQUE INDEX

CREATE INDEX ON topics ("topic_name" VARCHAR_PATTERN_OPS);
-- Allow registered users to create new posts on existing topics:
-- * Posts have a required title of at most 100 characters
-- * The title of a post can’t be empty.
-- * Posts should contain either a URL or a text content, but not both.
-- * If a topic gets deleted, all the posts associated with it should be automatically deleted too.
-- * If the user who created the post gets deleted, then the post will remain, but it will become dissociated from that user.
CREATE TABLE IF NOT EXISTS posts (
    id SERIAL PRIMARY KEY,
    post_title CHARACTER VARYING(100) NOT NULL,
    post_url CHARACTER VARYING DEFAULT NULL,
    post_content TEXT DEFAULT NULL,
    user_id INTEGER REFERENCES "users" ON DELETE CASCADE,
    topic_id INTEGER REFERENCES "topics" ON DELETE CASCADE,
    time_created TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT "title_not_null" CHECK ("post_title" IS NOT NULL),
    CONSTRAINT "title_not_empty" CHECK (LENGTH(TRIM("post_title")) > 0)
    CONSTRAINT "url_or_content" CHECK ( -- THIS IS SUPER COOL
        ("post_url" IS NOT NULL AND "post_content" IS NULL) OR
        ("post_content" IS NOT NULL AND "post_url" IS NULL)
    )
);

CREATE INDEX ON "posts" ("url" VARCHAR_PATTERN_OPS);

-- Allow registered users to comment on existing posts:
-- * A comment’s text content can’t be empty.
-- * Contrary to the current linear comments, the new structure should allow comment threads at arbitrary levels.
-- * If a post gets deleted, all comments associated with it should be automatically deleted too.
-- * If the user who created the comment gets deleted, then the comment will remain, but it will become dissociated from that user.
-- * If a comment gets deleted, then all its descendants in the thread structure should be automatically deleted too.
CREATE TABLE IF NOT EXISTS comments (
    id SERIAL PRIMARY KEY,
    comment_text TEXT NOT NULL,
    user_id INTEGER REFERENCES "users" ON DELETE SET NULL,
    post_id INTEGER REFERENCES "posts" ON DELETE CASCADE,
    comment_parent_id INTEGER REFERENCES "comments" ON DELETE CASCADE,
    time_created TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT "text_not_empty" CHECK (LENGTH(TRIM("comment_text")) > 0)
);

-- Make sure that a given user can only vote once on a given post:
-- Hint: you can store the (up/down) value of the vote as the values 1 and -1 respectively.
-- If the user who cast a vote gets deleted, then all their votes will remain, but will become dissociated from the user.
-- If a post gets deleted, then all the votes for that post should be automatically deleted too.
CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    vote SMALLINT DEFAULT 0,
    user_id INTEGER REFERENCES "users" ON DELETE SET NULL,
    post_id INTEGER REFERENCES "posts" ON DELETE CASCADE,
    time_created TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT "one_vote" UNIQUE(user_id, post_id),
    CONSTRAINT "vote_up_or_down" CHECK (
        "vote" = 1 OR "vote" = -1
    )
);

-- MIGRATE USERS FROM Bad Posts & Comments
INSERT INTO users ("username")
    SELECT DISTINCT username
    FROM bad_posts
    UNION
    SELECT DISTINCT username
    FROM bad_comments
    UNION
    SELECT DISTINCT regexp_split_to_table(upvotes, ',') AS username
    FROM bad_posts
    UNION
    SELECT DISTINCT regexp_split_to_table(downvotes, ',') AS username
    FROM bad_posts;

-- MIGRATE TOPICS
INSERT INTO topics ("topic_name")
    SELECT DISTINCT topic
    FROM bad_posts;


-- MIGRATE POSTS
INSERT INTO "posts" ("post_title", "post_url", "post_content", "user_id", "topic_id")
    SELECT LEFT(bad_posts.title, 100),
           bad_posts.url,
           bad_posts.text_content,
        --    CASE 
        --     WHEN bad_posts.url IS NOT NULL AND bad_posts.text_content IS NOT NULL THEN bad_posts.url
        --     WHEN bad_posts.url IS NOT NULL THEN bad_posts.url
        --     WHEN bad_posts.text_content IS NOT NULL THEN bad_posts.text_content
        --     ELSE NULL
        --    END,
           users.id,
           topics.id
    FROM bad_posts
    JOIN users ON bad_posts.username = users.username
    JOIN topics ON bad_posts.topic = topics.topic_name;

-- MIGRATE COMMENTS
INSERT INTO "comments" ("comment_text", "user_id", "post_id")
    SELECT bad_comments.text_content,
           posts.id,
           users.id
    FROM bad_comments
    JOIN users ON bad_comments.username = users.username
    JOIN posts ON posts.id = bad_comments.post_id;

-- MIGRATE VOTES
INSERT INTO "votes" ("vote", "user_id", "post_id")
    SELECT 1 AS "upvote",
           users.id,
           bp.id
    FROM (
        SELECT id,
               regexp_split_to_table(upvotes, ',') AS "upvote"
        FROM bad_posts
    ) bp
    JOIN users ON users.username = bp.upvote;

INSERT INTO "votes" ("vote", "user_id", "post_id")
    SELECT -1 AS "downvote",
           users.id,
           bp.id
    FROM (
        SELECT id,
               regexp_split_to_table(upvotes, ',') AS "downvote"
        FROM bad_posts
    ) bp
    JOIN users ON users.username = bp.downvote;