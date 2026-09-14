-- This file includes various fixtures that are useful when testing and running
-- a local setup of our applications
-- Users
INSERT INTO users (
  id,
  primary_email,
  email_verified,
  avatar_url,
  name,
  handle)
VALUES (
  '141c4ddf-2423-4f10-a4de-465939951354',
  'test@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Test User',
  'test'),
(
  'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
  'unison@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Unison Org',
  'unison'),
(
  '43efd5e7-139a-40b2-8a35-3f99b054dc84',
  'transcripts@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Transcript User',
  'transcripts'),
(
  '53efd5e7-139a-40b2-8a35-3f99b054dc84',
  'badscripts@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Transcript Non-org User',
  'badscripts'),
(
  '3dd1a929-28dd-4585-88aa-96b4dae8606d',
  'unauthorized@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Unauthorized User',
  'unauthorized'),
(
  'fe8921ca-aee7-40a2-8020-241ca78f2a5c',
  'admin@example.com',
  TRUE,
  'https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50?f=y&d=retro',
  'Admin User',
  'admin');

INSERT INTO cloud_daemon_users (id) VALUES ('141c4ddf-2423-4f10-a4de-465939951354'), ('e5e7635c-8db2-4b7f-9fee-86ee8d120ef9'), ('43efd5e7-139a-40b2-8a35-3f99b054dc84'), ('53efd5e7-139a-40b2-8a35-3f99b054dc84');

INSERT INTO cloud_clusters (id, 
                           name, 
                           hostname,
                           service_uri_type, 
                           service_uri,
                           cluster_uri,
                           user_id, 
                           created_by,
                           loki_uri,
                           loki_task_name)

VALUES ('ae35ed12-93f9-4915-92d5-4144e804b013',
    'default',
    'cloud-api',
    'local',
    'http://nimbus-0000:17011',
    'http://nimbus-0000:17011',
    'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
    'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
    'http://localhost:6666',
    'nimbus-local'
), ('a84b1dbf-667b-4823-a429-e280ff834807',
    'byoc',
    'localbyoc:5424',
    'local',
    'http://byoc-0000:17011',
    'http://byoc-0000:17011',
    'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
    'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
    'http://localbyoc:6666',
    'nimbus-byoc'
);

INSERT INTO cloud_cluster_tokens (cluster_id, created_by, token_hash)
VALUES
  ('ae35ed12-93f9-4915-92d5-4144e804b013', 
   'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9', 
   encode(sha512('nruObCVk0VrIzJyTH72HxXAdTf8hsU+cOZKiJ/Y99ARcdXLdzzqK9zB9EDUvrlyKJ9LckJ5uvUY='), 'hex')),
  ('a84b1dbf-667b-4823-a429-e280ff834807', 
   'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9', 
   encode(sha512('705da529-68b8-4a0d-a499-b1e3f94a4f3e'), 'hex'));

-- Insert subject and resource first, then use in orgs insert
WITH new_subject AS (
  INSERT INTO subjects (kind) VALUES ('org') RETURNING id
),
new_resource AS (
  INSERT INTO resources (kind) VALUES ('org') RETURNING id
)
INSERT INTO orgs (
  user_id,
  subject_id,
  resource_id
)
SELECT 
  'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
  new_subject.id,
  new_resource.id
FROM new_subject, new_resource;

INSERT INTO org_members (
  organization_user_id,
  member_user_id,
  org_id
  )
VALUES (
  'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
  '141c4ddf-2423-4f10-a4de-465939951354',
   (SELECT id from orgs WHERE user_id='e5e7635c-8db2-4b7f-9fee-86ee8d120ef9')
  ),(
  'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
  '43efd5e7-139a-40b2-8a35-3f99b054dc84',
   (SELECT id from orgs WHERE user_id='e5e7635c-8db2-4b7f-9fee-86ee8d120ef9')
  ),(
  'e5e7635c-8db2-4b7f-9fee-86ee8d120ef9',
  'fe8921ca-aee7-40a2-8020-241ca78f2a5c',
   (SELECT id from orgs WHERE user_id='e5e7635c-8db2-4b7f-9fee-86ee8d120ef9')
  );

INSERT INTO tours (
  user_id,
  tour_id)
VALUES (
  '141c4ddf-2423-4f10-a4de-465939951354',
  'welcome-terms'),
('43efd5e7-139a-40b2-8a35-3f99b054dc84',
  'welcome-terms'),
('53efd5e7-139a-40b2-8a35-3f99b054dc84',
  'welcome-terms');

-- User Profiles
UPDATE
  users
SET
  bio = 'A test user',
  website = 'https://unison-lang.org',
  location = 'The testverse',
  pronouns = 'they/them',
  twitterHandle = '@unisonTestUser'
WHERE
  id = '141c4ddf-2423-4f10-a4de-465939951354';

 

UPDATE
  users
SET
  bio = 'A transcript!',
  website = 'https://unison-lang.org',
  location = 'Unison Share',
  pronouns = 'they/them',
  twitterHandle = '@unisonTranscript'
WHERE
  id = '43efd5e7-139a-40b2-8a35-3f99b054dc84';

INSERT INTO cloud_users (user_id) VALUES ('141c4ddf-2423-4f10-a4de-465939951354'), 
('43efd5e7-139a-40b2-8a35-3f99b054dc84'),
('53efd5e7-139a-40b2-8a35-3f99b054dc84');

INSERT INTO cloud_environments (id, user_id, name, cluster_id)
VALUES
  ('86941601-c498-4a62-a1ca-a9359a46956b', '141c4ddf-2423-4f10-a4de-465939951354', 'empty', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('7e4aa5e7-81e7-4b8b-94f8-d531187aaf1a', '141c4ddf-2423-4f10-a4de-465939951354', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b', '141c4ddf-2423-4f10-a4de-465939951354', 'production', 'ae35ed12-93f9-4915-92d5-4144e804b013');

INSERT INTO cloud_deployments (user_id, deployment_hash, environment, cluster_id)
VALUES
  ('141c4ddf-2423-4f10-a4de-465939951354', 'BqVhDrNgHddFrNsEDRuxTUkeJUrnAGY8bFTNpe_r24Q', '7e4aa5e7-81e7-4b8b-94f8-d531187aaf1a', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'gozMQsGw_Z6vPM_Zt6ZDHRQyXgO4oq4fPDppp7ayPGE', '7e4aa5e7-81e7-4b8b-94f8-d531187aaf1a', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'zEE2syg0Zn0X9LYcOn11-kfi2D-4QtMS4qboLvo1ch0', '7e4aa5e7-81e7-4b8b-94f8-d531187aaf1a', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('141c4ddf-2423-4f10-a4de-465939951354', '5vHxUSHKNwfcwHND999W-IuAoDDLIAVJ8iIGGY_1aHs', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'RbSFV6bAgeEl2kxVOI1S_N6EGwxR8xHuMgks4ZLo4jQ', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'RskOG29_2PXABo2-q2fVl1LKnjiW7HFNmN6draRZ2T8', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b', 'ae35ed12-93f9-4915-92d5-4144e804b013');

INSERT INTO cloud_deployments (user_id, deployment_hash, environment, deployed_at, cluster_id)
VALUES
  ('141c4ddf-2423-4f10-a4de-465939951354', 'vcmaxTpA7Jpi2_xfKJo9QmSY8W7SoNb4eMqdyqgIons', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b', now() - interval '3 weeks', 'ae35ed12-93f9-4915-92d5-4144e804b013');


INSERT INTO cloud_deployments (user_id, deployment_hash, environment, deployed_at, undeployed_at, cluster_id)
VALUES
  ('141c4ddf-2423-4f10-a4de-465939951354', 'znO4Iplpblpa4hjzWzeyENq6BQjGT2dMauBGCrowmN4', '7e4aa5e7-81e7-4b8b-94f8-d531187aaf1a',  now() - interval '1 day', now() , 'ae35ed12-93f9-4915-92d5-4144e804b013' ),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'cqSLuw1xQwTau2x_N2tkiHaVh1DfHW7id3r1FBjFpsM', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b',  now() - interval '1 day', now(), 'ae35ed12-93f9-4915-92d5-4144e804b013' ),
  ('141c4ddf-2423-4f10-a4de-465939951354', 'O136mYnVQB40omox7XuP4HEZQRogVmbLyTAJid5eSd4', '0cf0ccb6-db0a-49d0-ba81-ba05a3e4ff9b',  now() - interval '1 day', now(), 'ae35ed12-93f9-4915-92d5-4144e804b013' );



INSERT INTO cloud_services (id, service_name, user_id, cluster_id)
VALUES
 ('e08984f8-c135-4032-8e86-6c481e0198e4', 'production-chatbot', '141c4ddf-2423-4f10-a4de-465939951354', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('b7d710fb-b845-4048-ba9a-919849452204', 'staging-chatbot', '141c4ddf-2423-4f10-a4de-465939951354', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('f3d0a092-4145-4a30-8acf-6ce8fcbdfc16', 'test-service', '141c4ddf-2423-4f10-a4de-465939951354', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('c3fb50d3-524a-4a4c-bcfa-1c6a8eae2584', 'empty-service', '141c4ddf-2423-4f10-a4de-465939951354', 'ae35ed12-93f9-4915-92d5-4144e804b013');


INSERT into cloud_service_assignments (user_id, service_id, deployment_hash, cluster_id)
VALUES
 ('141c4ddf-2423-4f10-a4de-465939951354', 'e08984f8-c135-4032-8e86-6c481e0198e4', 'BqVhDrNgHddFrNsEDRuxTUkeJUrnAGY8bFTNpe_r24Q', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'b7d710fb-b845-4048-ba9a-919849452204', 'gozMQsGw_Z6vPM_Zt6ZDHRQyXgO4oq4fPDppp7ayPGE', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'f3d0a092-4145-4a30-8acf-6ce8fcbdfc16', 'zEE2syg0Zn0X9LYcOn11-kfi2D-4QtMS4qboLvo1ch0', 'ae35ed12-93f9-4915-92d5-4144e804b013');

INSERT INTO cloud_deployment_tags ( user_id, deployment_hash, tag, cluster_id)
VALUES
 ('141c4ddf-2423-4f10-a4de-465939951354', 'BqVhDrNgHddFrNsEDRuxTUkeJUrnAGY8bFTNpe_r24Q', 'production', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'gozMQsGw_Z6vPM_Zt6ZDHRQyXgO4oq4fPDppp7ayPGE', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'zEE2syg0Zn0X9LYcOn11-kfi2D-4QtMS4qboLvo1ch0', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', '5vHxUSHKNwfcwHND999W-IuAoDDLIAVJ8iIGGY_1aHs', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'RbSFV6bAgeEl2kxVOI1S_N6EGwxR8xHuMgks4ZLo4jQ', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013');

INSERT into cloud_service_tags (user_id, service_id, tag, cluster_id)
VALUES
 ('141c4ddf-2423-4f10-a4de-465939951354', 'e08984f8-c135-4032-8e86-6c481e0198e4', 'production', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'b7d710fb-b845-4048-ba9a-919849452204', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'f3d0a092-4145-4a30-8acf-6ce8fcbdfc16', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013'),
 ('141c4ddf-2423-4f10-a4de-465939951354', 'c3fb50d3-524a-4a4c-bcfa-1c6a8eae2584', 'staging', 'ae35ed12-93f9-4915-92d5-4144e804b013');

INSERT INTO cloud_tiers (stripe_product_id, name, default_stripe_price_id)
VALUES
  ('prod_Ocnx7Qss9Do5sp', 'Starter', 'price_1NpYLPAYj7cJbPgwagvNxZFF'),
  ('prod_Ocny5shzYJTrJu', 'Pro', 'price_1NpYMGAYj7cJbPgw67zxxLBl');

INSERT INTO stripe_customers (stripe_customer_id, unison_user_id)
VALUES
  ('cust_abcdefg1', '141c4ddf-2423-4f10-a4de-465939951354'),
  ('cust_abcdefg2', '43efd5e7-139a-40b2-8a35-3f99b054dc84'),
  ('cust_abcdefg3', '53efd5e7-139a-40b2-8a35-3f99b054dc84');

INSERT INTO cloud_user_subscriptions (stripe_subscription_id, stripe_customer_id, stripe_product_id, status, paid_through)
VALUES
  ('sub_abcdefg1', 'cust_abcdefg1', 'prod_Ocnx7Qss9Do5sp', 'active', now() + interval '10 days'),
  ('sub_abcdefg2', 'cust_abcdefg2', 'prod_Ocnx7Qss9Do5sp', 'active', now() + interval '10 days'),
  ('sub_abcdefg3', 'cust_abcdefg3', 'prod_Ocnx7Qss9Do5sp', 'active', now() - interval '10 days');

