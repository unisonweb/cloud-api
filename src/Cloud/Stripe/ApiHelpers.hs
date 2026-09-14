module Cloud.Stripe.ApiHelpers
  (nestedForm)
where

import GHC.Exts (IsList (..))
import Web.FormUrlEncoded
import Cloud.Prelude

nestedForm :: Text -> Form -> Form
nestedForm name form = fromList $ map (\(k, v) -> (name <> "[" <> k <> "]", v)) $ toListStable form
