----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Interface.Rename
-- Copyright   :  (c) Simon Marlow 2003-2006,
--                    David Waern  2006-2009
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
-----------------------------------------------------------------------------
module Haddock.Interface.Rename (renameInterface) where


import Haddock.GhcUtils
import Haddock.Types

import Bag (emptyBag)
import GHC hiding (NoLink)
import Name

import Control.Applicative
import Control.Monad hiding (mapM)
import Data.List
import qualified Data.Map as Map hiding ( Map )
import Data.Traversable (mapM)
import Prelude hiding (mapM)


renameInterface :: DynFlags -> LinkEnv -> Bool -> Interface -> ErrMsgM Interface
renameInterface dflags renamingEnv warnings iface =

  -- first create the local env, where every name exported by this module
  -- is mapped to itself, and everything else comes from the global renaming
  -- env
  let localEnv = foldl fn renamingEnv (ifaceVisibleExports iface)
        where fn env name = Map.insert name (ifaceMod iface) env

      -- rename names in the exported declarations to point to things that
      -- are closer to, or maybe even exported by, the current module.
      (renamedExportItems, missingNames1)
        = runRnFM localEnv (renameExportItems (ifaceExportItems iface))

      (rnDocMap, missingNames2) = runRnFM localEnv (mapM renameDoc (ifaceDocMap iface))

      (rnArgMap, missingNames3) = runRnFM localEnv (mapM (mapM renameDoc) (ifaceArgMap iface))

      (finalModuleDoc, missingNames4)
        = runRnFM localEnv (renameDocumentation (ifaceDoc iface))

      -- combine the missing names and filter out the built-ins, which would
      -- otherwise allways be missing.
      missingNames = nub $ filter isExternalName  -- XXX: isExternalName filters out too much
                    (missingNames1 ++ missingNames2 ++ missingNames3 ++ missingNames4)

      -- filter out certain built in type constructors using their string
      -- representation. TODO: use the Name constants from the GHC API.
--      strings = filter (`notElem` ["()", "[]", "(->)"])
--                (map pretty missingNames)
      strings = map (pretty dflags) . filter (\n -> not (isSystemName n || isBuiltInSyntax n)) $ missingNames

  in do
    -- report things that we couldn't link to. Only do this for non-hidden
    -- modules.
    unless (OptHide `elem` ifaceOptions iface || null strings || not warnings) $
      tell ["Warning: " ++ moduleString (ifaceMod iface) ++
            ": could not find link destinations for:\n"++
            unwords ("   " : strings) ]

    return $ iface { ifaceRnDoc         = finalModuleDoc,
                     ifaceRnDocMap      = rnDocMap,
                     ifaceRnArgMap      = rnArgMap,
                     ifaceRnExportItems = renamedExportItems }


--------------------------------------------------------------------------------
-- Monad for renaming
--
-- The monad does two things for us: it passes around the environment for
-- renaming, and it returns a list of names which couldn't be found in
-- the environment.
--------------------------------------------------------------------------------


newtype GenRnM n a =
  RnM { unRn :: (n -> (Bool, DocName))  -- name lookup function
             -> (a,[n])
      }

type RnM a = GenRnM Name a

instance Monad (GenRnM n) where
  (>>=) = thenRn
  return = returnRn

instance Functor (GenRnM n) where
  fmap f x = do a <- x; return (f a)

instance Applicative (GenRnM n) where
  pure = return
  (<*>) = ap

returnRn :: a -> GenRnM n a
returnRn a   = RnM (const (a,[]))
thenRn :: GenRnM n a -> (a -> GenRnM n b) -> GenRnM n b
m `thenRn` k = RnM (\lkp -> case unRn m lkp of
  (a,out1) -> case unRn (k a) lkp of
    (b,out2) -> (b,out1++out2))

getLookupRn :: RnM (Name -> (Bool, DocName))
getLookupRn = RnM (\lkp -> (lkp,[]))
outRn :: Name -> RnM ()
outRn name = RnM (const ((),[name]))

lookupRn :: (DocName -> a) -> Name -> RnM a
lookupRn and_then name = do
  lkp <- getLookupRn
  case lkp name of
    (False,maps_to) -> do outRn name; return (and_then maps_to)
    (True, maps_to) -> return (and_then maps_to)


runRnFM :: LinkEnv -> RnM a -> (a,[Name])
runRnFM env rn = unRn rn lkp
  where
    lkp n = case Map.lookup n env of
      Nothing  -> (False, Undocumented n)
      Just mdl -> (True,  Documented n mdl)


--------------------------------------------------------------------------------
-- Renaming
--------------------------------------------------------------------------------


rename :: Name -> RnM DocName
rename = lookupRn id


renameL :: Located Name -> RnM (Located DocName)
renameL = mapM rename


renameExportItems :: [ExportItem Name] -> RnM [ExportItem DocName]
renameExportItems = mapM renameExportItem


renameDocForDecl :: DocForDecl Name -> RnM (DocForDecl DocName)
renameDocForDecl (doc, fnArgsDoc) =
  (,) <$> renameDocumentation doc <*> renameFnArgsDoc fnArgsDoc


renameDocumentation :: Documentation Name -> RnM (Documentation DocName)
renameDocumentation (Documentation mDoc mWarning) =
  Documentation <$> mapM renameDoc mDoc <*> mapM renameDoc mWarning


renameLDocHsSyn :: LHsDocString -> RnM LHsDocString
renameLDocHsSyn = return


renameDoc :: Doc Name -> RnM (Doc DocName)
renameDoc d = case d of
  DocEmpty -> return DocEmpty
  DocAppend a b -> do
    a' <- renameDoc a
    b' <- renameDoc b
    return (DocAppend a' b')
  DocString str -> return (DocString str)
  DocParagraph doc -> do
    doc' <- renameDoc doc
    return (DocParagraph doc')
  DocIdentifier x -> do
    x' <- rename x
    return (DocIdentifier x')
  DocIdentifierUnchecked x -> return (DocIdentifierUnchecked x)
  DocModule str -> return (DocModule str)
  DocWarning doc -> do
    doc' <- renameDoc doc
    return (DocWarning doc')
  DocEmphasis doc -> do
    doc' <- renameDoc doc
    return (DocEmphasis doc')
  DocMonospaced doc -> do
    doc' <- renameDoc doc
    return (DocMonospaced doc')
  DocUnorderedList docs -> do
    docs' <- mapM renameDoc docs
    return (DocUnorderedList docs')
  DocOrderedList docs -> do
    docs' <- mapM renameDoc docs
    return (DocOrderedList docs')
  DocDefList docs -> do
    docs' <- mapM (\(a,b) -> do
      a' <- renameDoc a
      b' <- renameDoc b
      return (a',b')) docs
    return (DocDefList docs')
  DocCodeBlock doc -> do
    doc' <- renameDoc doc
    return (DocCodeBlock doc')
  DocURL str -> return (DocURL str)
  DocPic str -> return (DocPic str)
  DocAName str -> return (DocAName str)
  DocExamples e -> return (DocExamples e)


renameFnArgsDoc :: FnArgsDoc Name -> RnM (FnArgsDoc DocName)
renameFnArgsDoc = mapM renameDoc


renameLType :: LHsType Name -> RnM (LHsType DocName)
renameLType = mapM renameType

renameLKind :: LHsKind Name -> RnM (LHsKind DocName)
renameLKind = renameLType

renameMaybeLKind :: Maybe (LHsKind Name)
                 -> RnM (Maybe (LHsKind DocName))
renameMaybeLKind Nothing = return Nothing
renameMaybeLKind (Just ki)
  = do { ki' <- renameLKind ki
       ; return (Just ki') }

renameType :: HsType Name -> RnM (HsType DocName)
renameType t = case t of
  HsForAllTy expl tyvars lcontext ltype -> do
    tyvars'   <- renameLTyVarBndrs tyvars
    lcontext' <- renameLContext lcontext
    ltype'    <- renameLType ltype
    return (HsForAllTy expl tyvars' lcontext' ltype')

  HsTyVar n -> return . HsTyVar =<< rename n
  HsBangTy b ltype -> return . HsBangTy b =<< renameLType ltype

  HsAppTy a b -> do
    a' <- renameLType a
    b' <- renameLType b
    return (HsAppTy a' b')

  HsFunTy a b -> do
    a' <- renameLType a
    b' <- renameLType b
    return (HsFunTy a' b')

  HsListTy ty -> return . HsListTy =<< renameLType ty
  HsPArrTy ty -> return . HsPArrTy =<< renameLType ty
  HsIParamTy n ty -> liftM (HsIParamTy n) (renameLType ty)
  HsEqTy ty1 ty2 -> liftM2 HsEqTy (renameLType ty1) (renameLType ty2)

  HsTupleTy b ts -> return . HsTupleTy b =<< mapM renameLType ts

  HsOpTy a (w, L loc op) b -> do
    op' <- rename op
    a'  <- renameLType a
    b'  <- renameLType b
    return (HsOpTy a' (w, L loc op') b')

  HsParTy ty -> return . HsParTy =<< renameLType ty

  HsKindSig ty k -> do
    ty' <- renameLType ty
    k' <- renameLKind k
    return (HsKindSig ty' k')

  HsDocTy ty doc -> do
    ty' <- renameLType ty
    doc' <- renameLDocHsSyn doc
    return (HsDocTy ty' doc')

  HsTyLit x -> return (HsTyLit x)

  _ -> error "renameType"


renameLTyVarBndrs :: LHsTyVarBndrs Name -> RnM (LHsTyVarBndrs DocName)
renameLTyVarBndrs (HsQTvs { hsq_kvs = _, hsq_tvs = tvs })
  = do { tvs' <- mapM renameLTyVarBndr tvs
       ; return (HsQTvs { hsq_kvs = error "haddock:renameLTyVarBndrs", hsq_tvs = tvs' }) }
                -- This is rather bogus, but I'm not sure what else to do

renameLTyVarBndr :: LHsTyVarBndr Name -> RnM (LHsTyVarBndr DocName)
renameLTyVarBndr (L loc (UserTyVar n))
  = do { n' <- rename n
       ; return (L loc (UserTyVar n')) }
renameLTyVarBndr (L loc (KindedTyVar n k))
  = do { n' <- rename n
       ; k' <- renameLKind k
       ; return (L loc (KindedTyVar n' k')) }

renameLContext :: Located [LHsType Name] -> RnM (Located [LHsType DocName])
renameLContext (L loc context) = do
  context' <- mapM renameLType context
  return (L loc context')


renameInstHead :: InstHead Name -> RnM (InstHead DocName)
renameInstHead (preds, className, types) = do
  preds' <- mapM renameType preds
  className' <- rename className
  types' <- mapM renameType types
  return (preds', className', types')


renameLDecl :: LHsDecl Name -> RnM (LHsDecl DocName)
renameLDecl (L loc d) = return . L loc =<< renameDecl d


renameDecl :: HsDecl Name -> RnM (HsDecl DocName)
renameDecl decl = case decl of
  TyClD d -> do
    d' <- renameTyClD d
    return (TyClD d')
  SigD s -> do
    s' <- renameSig s
    return (SigD s')
  ForD d -> do
    d' <- renameForD d
    return (ForD d')
  InstD d -> do
    d' <- renameInstD d
    return (InstD d')
  _ -> error "renameDecl"

renameLThing :: (a Name -> RnM (a DocName)) -> Located (a Name) -> RnM (Located (a DocName))
renameLThing fn (L loc x) = return . L loc =<< fn x

renameTyClD :: TyClDecl Name -> RnM (TyClDecl DocName)
renameTyClD d = case d of
  ForeignType lname b -> do
    lname' <- renameL lname
    return (ForeignType lname' b)

--  TyFamily flav lname ltyvars kind tckind -> do
  FamDecl { tcdFam = decl } -> do
    decl' <- renameFamilyDecl decl
    return (FamDecl { tcdFam = decl' })

  SynDecl { tcdLName = lname, tcdTyVars = tyvars, tcdRhs = rhs, tcdFVs = fvs } -> do
    lname'    <- renameL lname
    tyvars'   <- renameLTyVarBndrs tyvars
    rhs'     <- renameLType rhs
    return (SynDecl { tcdLName = lname', tcdTyVars = tyvars', tcdRhs = rhs', tcdFVs = fvs })

  DataDecl { tcdLName = lname, tcdTyVars = tyvars, tcdDataDefn = defn, tcdFVs = fvs } -> do
    lname'    <- renameL lname
    tyvars'   <- renameLTyVarBndrs tyvars
    defn'     <- renameDataDefn defn
    return (DataDecl { tcdLName = lname', tcdTyVars = tyvars', tcdDataDefn = defn', tcdFVs = fvs })

  ClassDecl { tcdCtxt = lcontext, tcdLName = lname, tcdTyVars = ltyvars
            , tcdFDs = lfundeps, tcdSigs = lsigs, tcdATs = ats, tcdATDefs = at_defs } -> do
    lcontext' <- renameLContext lcontext
    lname'    <- renameL lname
    ltyvars'  <- renameLTyVarBndrs ltyvars
    lfundeps' <- mapM renameLFunDep lfundeps
    lsigs'    <- mapM renameLSig lsigs
    ats'      <- mapM (renameLThing renameFamilyDecl) ats
    at_defs'  <- mapM (mapM renameTyFamInstD) at_defs
    -- we don't need the default methods or the already collected doc entities
    return (ClassDecl { tcdCtxt = lcontext', tcdLName = lname', tcdTyVars = ltyvars'
                      , tcdFDs = lfundeps', tcdSigs = lsigs', tcdMeths= emptyBag
                      , tcdATs = ats', tcdATDefs = at_defs', tcdDocs = [], tcdFVs = placeHolderNames })

  where
    renameLFunDep (L loc (xs, ys)) = do
      xs' <- mapM rename xs
      ys' <- mapM rename ys
      return (L loc (xs', ys'))

    renameLSig (L loc sig) = return . L loc =<< renameSig sig

renameFamilyDecl :: FamilyDecl Name -> RnM (FamilyDecl DocName)
renameFamilyDecl (FamilyDecl { fdFlavour = flav, fdLName = lname
                             , fdTyVars = ltyvars, fdKindSig = tckind }) = do
    lname'   <- renameL lname
    ltyvars' <- renameLTyVarBndrs ltyvars
    tckind'  <- renameMaybeLKind tckind
    return (FamilyDecl { fdFlavour = flav, fdLName = lname'
                       , fdTyVars = ltyvars', fdKindSig = tckind' })

renameDataDefn :: HsDataDefn Name -> RnM (HsDataDefn DocName)
renameDataDefn (HsDataDefn { dd_ND = nd, dd_ctxt = lcontext, dd_cType = cType
                           , dd_kindSig = k, dd_cons = cons }) = do
    lcontext' <- renameLContext lcontext
    k'        <- renameMaybeLKind k
    cons'     <- mapM (mapM renameCon) cons
    -- I don't think we need the derivings, so we return Nothing
    return (HsDataDefn { dd_ND = nd, dd_ctxt = lcontext', dd_cType = cType
                       , dd_kindSig = k', dd_cons = cons', dd_derivs = Nothing })

renameCon :: ConDecl Name -> RnM (ConDecl DocName)
renameCon decl@(ConDecl { con_name = lname, con_qvars = ltyvars
                        , con_cxt = lcontext, con_details = details
                        , con_res = restype, con_doc = mbldoc }) = do
      lname'    <- renameL lname
      ltyvars'  <- renameLTyVarBndrs ltyvars
      lcontext' <- renameLContext lcontext
      details'  <- renameDetails details
      restype'  <- renameResType restype
      mbldoc'   <- mapM renameLDocHsSyn mbldoc
      return (decl { con_name = lname', con_qvars = ltyvars', con_cxt = lcontext'
                   , con_details = details', con_res = restype', con_doc = mbldoc' })
  where
    renameDetails (RecCon fields) = return . RecCon =<< mapM renameField fields
    renameDetails (PrefixCon ps) = return . PrefixCon =<< mapM renameLType ps
    renameDetails (InfixCon a b) = do
      a' <- renameLType a
      b' <- renameLType b
      return (InfixCon a' b')

    renameField (ConDeclField name t doc) = do
      name' <- renameL name
      t'   <- renameLType t
      doc' <- mapM renameLDocHsSyn doc
      return (ConDeclField name' t' doc')

    renameResType (ResTyH98) = return ResTyH98
    renameResType (ResTyGADT t) = return . ResTyGADT =<< renameLType t

renameSig :: Sig Name -> RnM (Sig DocName)
renameSig sig = case sig of
  TypeSig lnames ltype -> do
    lnames' <- mapM renameL lnames
    ltype' <- renameLType ltype
    return (TypeSig lnames' ltype')
  -- we have filtered out all other kinds of signatures in Interface.Create
  _ -> error "expected TypeSig"


renameForD :: ForeignDecl Name -> RnM (ForeignDecl DocName)
renameForD (ForeignImport lname ltype co x) = do
  lname' <- renameL lname
  ltype' <- renameLType ltype
  return (ForeignImport lname' ltype' co x)
renameForD (ForeignExport lname ltype co x) = do
  lname' <- renameL lname
  ltype' <- renameLType ltype
  return (ForeignExport lname' ltype' co x)


renameInstD :: InstDecl Name -> RnM (InstDecl DocName)
renameInstD (ClsInstD { cid_inst = d }) = do
  d' <- renameClsInstD d
  return (ClsInstD { cid_inst = d' })
renameInstD (TyFamInstD { tfid_inst = d }) = do
  d' <- renameTyFamInstD d
  return (TyFamInstD { tfid_inst = d' })
renameInstD (DataFamInstD { dfid_inst = d }) = do
  d' <- renameDataFamInstD d
  return (DataFamInstD { dfid_inst = d' })

renameClsInstD :: ClsInstDecl Name -> RnM (ClsInstDecl DocName)
renameClsInstD (ClsInstDecl { cid_poly_ty =ltype, cid_tyfam_insts = lATs, cid_datafam_insts = lADTs }) = do
  ltype' <- renameLType ltype
  lATs'  <- mapM (mapM renameTyFamInstD) lATs
  lADTs' <- mapM (mapM renameDataFamInstD) lADTs
  return (ClsInstDecl { cid_poly_ty = ltype', cid_binds = emptyBag, cid_sigs = []
                      , cid_tyfam_insts = lATs', cid_datafam_insts = lADTs' })


renameTyFamInstD :: TyFamInstDecl Name -> RnM (TyFamInstDecl DocName)
renameTyFamInstD (TyFamInstDecl { tfid_eqns = eqns , tfid_group = eqn_group })
  = do { eqns' <- mapM (renameLThing renameTyFamInstEqn) eqns
       ; return (TyFamInstDecl { tfid_eqns = eqns'
                               , tfid_group = eqn_group
                               , tfid_fvs = placeHolderNames }) }

renameTyFamInstEqn :: TyFamInstEqn Name -> RnM (TyFamInstEqn DocName)
renameTyFamInstEqn (TyFamInstEqn { tfie_tycon = tc, tfie_pats = pats_w_bndrs, tfie_rhs = rhs })
  = do { tc' <- renameL tc
       ; pats' <- mapM renameLType (hswb_cts pats_w_bndrs)
       ; rhs' <- renameLType rhs 
       ; return (TyFamInstEqn { tfie_tycon = tc', tfie_pats = pats_w_bndrs { hswb_cts = pats' }
                              , tfie_rhs = rhs' }) }

renameDataFamInstD :: DataFamInstDecl Name -> RnM (DataFamInstDecl DocName)
renameDataFamInstD (DataFamInstDecl { dfid_tycon = tc, dfid_pats = pats_w_bndrs, dfid_defn = defn })
  = do { tc' <- renameL tc
       ; pats' <- mapM renameLType (hswb_cts pats_w_bndrs)
       ; defn' <- renameDataDefn defn 
       ; return (DataFamInstDecl { dfid_tycon = tc', dfid_pats = pats_w_bndrs { hswb_cts = pats' }
                                 , dfid_defn = defn', dfid_fvs = placeHolderNames }) }

renameExportItem :: ExportItem Name -> RnM (ExportItem DocName)
renameExportItem item = case item of
  ExportModule mdl -> return (ExportModule mdl)
  ExportGroup lev id_ doc -> do
    doc' <- renameDoc doc
    return (ExportGroup lev id_ doc')
  ExportDecl decl doc subs instances -> do
    decl' <- renameLDecl decl
    doc'  <- renameDocForDecl doc
    subs' <- mapM renameSub subs
    instances' <- forM instances $ \(inst, idoc) -> do
      inst' <- renameInstHead inst
      idoc' <- mapM renameDoc idoc
      return (inst', idoc')
    return (ExportDecl decl' doc' subs' instances')
  ExportNoDecl x subs -> do
    x'    <- lookupRn id x
    subs' <- mapM (lookupRn id) subs
    return (ExportNoDecl x' subs')
  ExportDoc doc -> do
    doc' <- renameDoc doc
    return (ExportDoc doc')


renameSub :: (Name, DocForDecl Name) -> RnM (DocName, DocForDecl DocName)
renameSub (n,doc) = do
  n' <- rename n
  doc' <- renameDocForDecl doc
  return (n', doc')
