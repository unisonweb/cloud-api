module Cloud.Postgres.Queries.Metrics
  ( uniqueUsersLastWeek,
    uniqueUsersLastMonth,
    uniqueUsers,
    everActiveUsers,
    numDeploymentsLastWeek,
    numStoragePoolsCreatedLastWeek,
    numUsersWithStorage,
    numUsersWithServices,
    numUsersWithDeployments,
    numUsersWithJobs,
    usersWithJobsOrServicesLastWeek,
    usersWithJobsOrServicesLastMonth,
    usersWithDeploymentsNotProjectsLastWeek,
    userWithDeploymentsNotProjectsLastMonth,
    usersWithProjects,
    usersWithServices,
    numActiveSubscriptions,
    numJobsRunLastWeek,
    numServiceAssignmentsLastWeek,
    numServicesCreatedLastWeek,
  )
where

import Cloud.Postgres qualified as PG
import Data.Int (Int64)

uniqueUsers :: PG.Transaction e Int64
uniqueUsers = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_users
      |]

everActiveUsers :: PG.Transaction e Int64
everActiveUsers = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_users
            WHERE last_activity > '2023-08-16'
      |]

uniqueUsersLastWeek :: PG.Transaction e Int64
uniqueUsersLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_users
            WHERE last_activity > NOW() - INTERVAL '7 days'
      |]

uniqueUsersLastMonth :: PG.Transaction e Int64
uniqueUsersLastMonth = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_users
            WHERE last_activity > NOW() - INTERVAL '1 month'
      |]

usersWithJobsOrServicesLastWeek :: PG.Transaction e Int64
usersWithJobsOrServicesLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
      SELECT COUNT(*)
      FROM users u
      WHERE u.handle <> 'cloud'
        AND (
          EXISTS (
            SELECT
            FROM cloud_services s
            WHERE s.user_id = u.id
              AND s.created_at > NOW() - INTERVAL '7 days'
          )
          OR EXISTS (
            SELECT
            FROM cloud_deployments d
            WHERE d.user_id = u.id
              AND d.deployed_at > NOW() - INTERVAL '7 days'
          )
        );
      |]

usersWithJobsOrServicesLastMonth :: PG.Transaction e Int64
usersWithJobsOrServicesLastMonth = do
  PG.queryExpect1Col
    [PG.sql|
      SELECT COUNT(*)
      FROM users u
      WHERE u.handle <> 'cloud'
      AND (
        EXISTS (
          SELECT
          FROM cloud_services s
          WHERE s.user_id = u.id
            AND s.created_at > NOW() - INTERVAL '1 month'
        )
        OR EXISTS (
          SELECT
          FROM cloud_deployments d
          WHERE d.user_id = u.id
            AND d.deployed_at > NOW() - INTERVAL '1 month'
        )
      );
      |]

usersWithProjects :: PG.Transaction e Int64
usersWithProjects = do
  PG.queryExpect1Col
    [PG.sql|
      SELECT COUNT(*)
      FROM users u
      WHERE u.handle <> 'cloud'
       AND EXISTS (
         SELECT
         FROM projects p
         WHERE p.owner_user_id = u.id
 );
      |]

usersWithServices :: PG.Transaction e Int64
usersWithServices = do
  PG.queryExpect1Col
    [PG.sql|
    SELECT COUNT(*)
    FROM users u
    WHERE u.handle <> 'cloud'
     AND EXISTS (
       SELECT
       FROM cloud_services s
       WHERE s.user_id = u.id
     );
      |]

usersWithDeploymentsNotProjectsLastWeek :: PG.Transaction e Int64
usersWithDeploymentsNotProjectsLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(DISTINCT(u.id))
          FROM users u
          LEFT JOIN cloud_deployments d
            ON u.id = d.user_id
          LEFT JOIN projects p
            ON u.id = p.owner_user_id
          WHERE u.handle <> 'cloud'
            AND u.handle <> 'unison'
            AND d.deployed_at > NOW() - INTERVAL '7 days'
            AND p.created_at < NOW() - INTERVAL '7 days'
      |]

userWithDeploymentsNotProjectsLastMonth :: PG.Transaction e Int64
userWithDeploymentsNotProjectsLastMonth = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(DISTINCT(u.id))
          FROM users u
          LEFT JOIN cloud_deployments d
            ON u.id = d.user_id
          LEFT JOIN projects p
            ON u.id = p.owner_user_id
          WHERE u.handle <> 'cloud'
            AND d.deployed_at > NOW() - INTERVAL '1 month'
            AND p.created_at < NOW() - INTERVAL '1 month'
      |]

numActiveSubscriptions :: PG.Transaction e Int64
numActiveSubscriptions = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_user_subscriptions cus
          JOIN stripe_customers sc
            ON sc.stripe_customer_id = cus.stripe_customer_id
          JOIN users u
            ON u.id = sc.unison_user_id
          LEFT JOIN org_members om
            ON om.member_user_id = u.id
          WHERE cus.paid_through::date >= now()::date
            AND om.created_at IS NULL
         |]

numDeploymentsLastWeek :: PG.Transaction e Int64
numDeploymentsLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
        FROM cloud_deployments d
          JOIN users u
            ON u.id = d.user_id
            WHERE u.handle <> 'cloud'
            AND d.deployed_at > NOW() - INTERVAL '7 days'
      |]

numUsersWithServices :: PG.Transaction e Int64
numUsersWithServices = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(DISTINCT(s.user_id))
          FROM users u
          JOIN cloud_services s
            ON u.id = s.user_id
          WHERE u.handle <> 'cloud'
      |]

numServicesCreatedLastWeek :: PG.Transaction e Int64
numServicesCreatedLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(s.id)
          FROM cloud_services s
          JOIN users u
            ON u.id = s.user_id
            WHERE u.handle <> 'cloud'
              AND s.created_at > NOW() - INTERVAL '7 days'
      |]

numServiceAssignmentsLastWeek :: PG.Transaction e Int64
numServiceAssignmentsLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(s.*)
          FROM cloud_service_assignments s
          JOIN users u
            ON u.id = s.user_id
            WHERE u.handle <> 'cloud'
              AND s.assignment_time > NOW() - INTERVAL '7 days'
      |]

numJobsRunLastWeek :: PG.Transaction e Int64
numJobsRunLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(j.id)
          FROM cloud_jobs j
          JOIN users u ON u.id = j.user_id
            WHERE u.handle <> 'cloud'
            AND j.launched_at > NOW() - INTERVAL '7 days'
      |]

numUsersWithJobs :: PG.Transaction e Int64
numUsersWithJobs = do
  PG.queryExpect1Col
    [PG.sql|
      SELECT COUNT(*)
      FROM users u
      WHERE u.handle <> 'cloud'
        AND EXISTS (
          SELECT 
          FROM cloud_jobs j
          WHERE j.user_id = u.id
        );
      |]

numStoragePoolsCreatedLastWeek :: PG.Transaction e Int64
numStoragePoolsCreatedLastWeek = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(*)
          FROM cloud_storage_pools s
          JOIN users u ON u.id = s.user_id
            WHERE u.handle <> 'cloud'
              AND s.created_at > NOW() - INTERVAL '7 days'
      |]

numUsersWithStorage :: PG.Transaction e Int64
numUsersWithStorage = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(DISTINCT user_id)
          FROM cloud_storage_pools s
          JOIN users u ON u.id = s.user_id
            WHERE u.handle <> 'cloud'
      |]

-- we need to exclude the user with the handle "cloud" from this query because integration-tests throw this off
numUsersWithDeployments :: PG.Transaction e Int64
numUsersWithDeployments = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT COUNT(DISTINCT(d.user_id))
        FROM users u
        JOIN cloud_deployments d ON u.id = d.user_id
        WHERE u.handle != 'cloud'
      |]
