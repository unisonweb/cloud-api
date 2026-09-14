{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cloud.Prelude.Orphans where

import GHC.TypeError qualified as TypeError
import Hasql.Interpolate qualified as Interp
import Web.HttpApiData (FromHttpApiData (parseUrlPiece))
import Network.URI (URIAuth, URI (URI), parseURIReference)
import qualified Data.Text as Text

instance {-# OVERLAPPING #-} (TypeError.TypeError ('TypeError.Text "A String will be encoded as char[], Did you mean to use Text instead?")) => Interp.EncodeValue String where
  encodeValue = error "unpossible"

instance {-# OVERLAPPING #-} (TypeError.TypeError ('TypeError.Text "Strings are decoded as a char[], Did you mean to use Text instead?")) => Interp.DecodeValue String where
  decodeValue = error "unpossible"

instance FromHttpApiData URIAuth where
  parseUrlPiece s = case parseURIReference (Text.unpack s) of
    Just (URI _ (Just uriAuth) _ _ _) -> Right uriAuth
    _ -> Left $ "Invalid URI authority: '" <> s <> "'"
