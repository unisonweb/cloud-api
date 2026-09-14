module Main where

import Cloud (startApp)
import Env (withEnv)

main :: IO ()
main =
  withEnv startApp
