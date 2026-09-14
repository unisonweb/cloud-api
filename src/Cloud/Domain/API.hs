{-# LANGUAGE DataKinds #-}

module Cloud.Domain.API
  ( DomainAPI,
    ListDomainsAPI,
    CreateDomainAPI,
    GetDomainAPI,
    DeleteDomainAPI,
  )
where

import Cloud.Domain.Types
import Cloud.Service.Types (ServiceName)
import Servant
import Share.OAuth.Session (AuthenticatedUserId)

type DomainAPI =
  "domains"
    :> ( ListDomainsAPI
           :<|> CreateDomainAPI
           :<|> GetDomainAPI
           :<|> DeleteDomainAPI
       )

type ListDomainsAPI =
  AuthenticatedUserId
    :> Get '[JSON] [DomainDetails]

type CreateDomainAPI =
  AuthenticatedUserId
    :> Capture "domain" DomainName
    :> Capture "ServiceName" ServiceName
    :> Post '[JSON] DomainDetails

type GetDomainAPI =
  AuthenticatedUserId
    :> Capture "domain" DomainName
    :> Get '[JSON] DomainDetails

type DeleteDomainAPI =
  AuthenticatedUserId
    :> Capture "domain" DomainName
    :> DeleteNoContent
