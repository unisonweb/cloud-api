module Cloud.Postgres.Env (
  PostgresEnv(..),
)

where

import qualified Hasql.Pool as Hasql

data PostgresEnv = PostgresEnv {
    pgConnectionPool :: Hasql.Pool
  
}

 
