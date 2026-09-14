{-|
Description : Consul query filters

See [the Consul filtering docs](https://developer.hashicorp.com/consul/api-docs/features/filtering).
-}
module Cloud.Consul.Filtering
where
import Cloud.Prelude
import Data.Text (intercalate)
import Web.HttpApiData (ToHttpApiData, ToHttpApiData(toQueryParam))

data Selector = Selector Text [Text]

renderSelector :: Selector -> Text
renderSelector (Selector h t) = intercalate "." (h : t)

selectField :: Text -> Selector
selectField h = Selector h []

data Value = IntValue Int | FloatValue Double | StringValue Text | SelectorValue Selector

renderValue :: Value -> Text
renderValue (IntValue i) = tshow i
renderValue (FloatValue f) = tshow f
renderValue (StringValue t) = "`" <> t <> "`"
renderValue (SelectorValue s) = renderSelector s

data Op = Equals Selector Value | In Value Selector

renderOp :: Op -> Text
renderOp (Equals selector value) = renderSelector selector <> " == " <> renderValue value
renderOp (In value selector) = renderValue value <> " in " <> renderSelector selector

data Filter = Match Op | Not Filter

instance ToHttpApiData Filter where
  toQueryParam = renderFilter

renderFilter :: Filter -> Text
renderFilter (Match op) = renderOp op
renderFilter (Not e) = "not (" <> renderFilter e <> ")"
