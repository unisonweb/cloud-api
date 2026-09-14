CREATE TABLE cloud_daemon_users (
    id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE
);
INSERT INTO cloud_daemon_users (id) 
    select u.id from users u join stripe_customers sc on sc.unison_user_id=u.id join cloud_user_subscriptions cus on cus.stripe_customer_id = sc.stripe_customer_id;

INSERT INTO cloud_daemon_users (id) 
    select u.id from users ou join orgs o on o.user_id=ou.id join org_members om on om.organization_user_id=ou.id join users u on u.id=om.member_user_id where ou.handle='cloud';
