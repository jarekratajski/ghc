%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[RnSource]{Main pass of renamer}

\begin{code}
#include "HsVersions.h"

module RnSource ( rnSource, rnPolyType ) where

import Ubiq
import RnLoop		-- *check* the RnPass4/RnExpr4/RnBinds4 loop-breaking

import HsSyn
import HsPragmas
import RdrHsSyn
import RnHsSyn
import RnMonad
import RnBinds		( rnTopBinds, rnMethodBinds )

import Bag		( bagToList )
import Class		( derivableClassKeys )
import ListSetOps	( unionLists, minusList )
import Maybes		( maybeToBool, catMaybes )
import Name		( isLocallyDefined, isAvarid, getLocalName, ExportFlag(..), RdrName )
import Pretty
import SrcLoc		( SrcLoc )
import Unique		( Unique )
import UniqFM		( addListToUFM, listToUFM )
import UniqSet		( UniqSet(..) )
import Util		( isn'tIn, panic, assertPanic )

rnExports mods Nothing     = returnRn (\n -> ExportAll)
rnExports mods (Just exps) = returnRn (\n -> ExportAll)
\end{code}

rnSource `renames' the source module and export list.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
\item
Checks that all variable occurences are defined.
\item 
Checks the (..) etc constraints in the export list.
\end{enumerate}


\begin{code}
rnSource :: [Module]				-- imported modules
	 -> Bag RenamedFixityDecl		-- fixity info for imported names
	 -> RdrNameHsModule
	 -> RnM s (RenamedHsModule,
		   Name -> ExportFlag,		-- export info
		   Bag (RnName, RdrName))	-- occurrence info

rnSource imp_mods imp_fixes (HsModule mod version exports _ fixes
	                       ty_decls specdata_sigs class_decls
	                       inst_decls specinst_sigs defaults
	                       binds _ src_loc)

  = pushSrcLocRn src_loc $

    rnExports (mod:imp_mods) exports	`thenRn` \ exported_fn ->
    rnFixes fixes			`thenRn` \ src_fixes ->
    let
	pair_name (InfixL n i) = (n, i)
	pair_name (InfixR n i) = (n, i)
	pair_name (InfixN n i) = (n, i)

	imp_fixes_fm = listToUFM (map pair_name (bagToList imp_fixes))
	all_fixes_fm = addListToUFM imp_fixes_fm (map pair_name src_fixes)
    in
    setExtraRn {-all_fixes_fm-}(panic "rnSource:all_fixes_fm") $

    mapRn rnTyDecl	ty_decls	`thenRn` \ new_ty_decls ->
    mapRn rnSpecDataSig specdata_sigs	`thenRn` \ new_specdata_sigs ->
    mapRn rnClassDecl	class_decls	`thenRn` \ new_class_decls ->
    mapRn rnInstDecl	inst_decls	`thenRn` \ new_inst_decls ->
    mapRn rnSpecInstSig specinst_sigs   `thenRn` \ new_specinst_sigs ->
    rnDefaultDecl	defaults	`thenRn` \ new_defaults ->
    rnTopBinds binds			`thenRn` \ new_binds ->

    getOccurrenceUpRn			`thenRn` \ occ_info ->

    returnRn (
	      HsModule mod version
		trashed_exports trashed_imports
		{-new_fixes-}(panic "rnSource:new_fixes (Hi, Patrick!)")
		new_ty_decls new_specdata_sigs new_class_decls
		new_inst_decls new_specinst_sigs new_defaults
		new_binds [] src_loc,
	      exported_fn,
	      occ_info
	     )
  where
    trashed_exports = panic "rnSource:trashed_exports"
    trashed_imports = panic "rnSource:trashed_imports"
\end{code}

%*********************************************************
%*							*
\subsection{Type declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its Name representation. In some cases (type signatures of
values), it is even necessary to go over the type first in order to
get the set of tyvars used by it, make an assoc list, and then go over
it again to rename the tyvars! However, we can also do some scoping
checks at the same time.

\begin{code}
rnTyDecl :: RdrNameTyDecl -> RnM_Fixes s RenamedTyDecl

rnTyDecl (TyData context tycon tyvars condecls derivings pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon tycon		       `thenRn` \ tycon' ->
    mkTyVarNamesEnv src_loc tyvars     `thenRn` \ (tv_env, tyvars') ->
    rnContext tv_env context	       `thenRn` \ context' ->
    rnConDecls tv_env condecls	       `thenRn` \ condecls' ->
    rn_derivs tycon' src_loc derivings `thenRn` \ derivings' ->
    ASSERT(isNoDataPragmas pragmas)
    returnRn (TyData context' tycon' tyvars' condecls' derivings' noDataPragmas src_loc)

rnTyDecl (TyNew context tycon tyvars condecl derivings pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon tycon		      `thenRn` \ tycon' ->
    mkTyVarNamesEnv src_loc tyvars    `thenRn` \ (tv_env, tyvars') ->
    rnContext tv_env context	      `thenRn` \ context' ->
    rnConDecls tv_env condecl	      `thenRn` \ condecl' ->
    rn_derivs tycon' src_loc derivings `thenRn` \ derivings' ->
    ASSERT(isNoDataPragmas pragmas)
    returnRn (TyNew context' tycon' tyvars' condecl' derivings' noDataPragmas src_loc)

rnTyDecl (TySynonym name tyvars ty src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon name		    `thenRn` \ name' ->
    mkTyVarNamesEnv src_loc tyvars  `thenRn` \ (tv_env, tyvars') ->
    rnMonoType tv_env ty	    `thenRn` \ ty' ->
    returnRn (TySynonym name' tyvars' ty' src_loc)

rn_derivs tycon2 locn Nothing -- derivs not specified
  = returnRn Nothing

rn_derivs tycon2 locn (Just ds)
  = mapRn (rn_deriv tycon2 locn) ds `thenRn` \ derivs ->
    returnRn (Just derivs)
  where
    rn_deriv tycon2 locn clas
      = lookupClass clas	    `thenRn` \ clas_name ->
	addErrIfRn (uniqueOf clas_name `not_elem` derivableClassKeys)
		   (derivingNonStdClassErr clas locn)
				    `thenRn_`
	returnRn clas_name
      where
	not_elem = isn'tIn "rn_deriv"
\end{code}

@rnConDecls@ uses the `global name function' to create a new
constructor in which local names have been replaced by their original
names, reporting any unknown names.

\begin{code}
rnConDecls :: TyVarNamesEnv
	   -> [RdrNameConDecl]
	   -> RnM_Fixes s [RenamedConDecl]

rnConDecls tv_env con_decls
  = mapRn rn_decl con_decls
  where
    rn_decl (ConDecl name tys src_loc)
      = pushSrcLocRn src_loc $
	lookupValue name	`thenRn` \ new_name ->
	mapRn rn_bang_ty tys	`thenRn` \ new_tys  ->
	returnRn (ConDecl new_name new_tys src_loc)

    rn_decl (ConOpDecl ty1 op ty2 src_loc)
      = pushSrcLocRn src_loc $
	lookupValue op		`thenRn` \ new_op  ->
	rn_bang_ty ty1  	`thenRn` \ new_ty1 ->
	rn_bang_ty ty2  	`thenRn` \ new_ty2 ->
	returnRn (ConOpDecl new_ty1 new_op new_ty2 src_loc)

    rn_decl (NewConDecl name ty src_loc)
      = pushSrcLocRn src_loc $
	lookupValue name	`thenRn` \ new_name ->
	rn_mono_ty ty		`thenRn` \ new_ty  ->
	returnRn (NewConDecl new_name new_ty src_loc)

    rn_decl (RecConDecl con fields src_loc)
      = panic "rnConDecls:RecConDecl"

    ----------
    rn_mono_ty = rnMonoType tv_env

    rn_bang_ty (Banged ty)
      = rn_mono_ty ty `thenRn` \ new_ty ->
	returnRn (Banged new_ty)
    rn_bang_ty (Unbanged ty)
      = rn_mono_ty ty `thenRn` \ new_ty ->
	returnRn (Unbanged new_ty)
\end{code}

%*********************************************************
%*							*
\subsection{SPECIALIZE data pragmas}
%*							*
%*********************************************************

\begin{code}
rnSpecDataSig :: RdrNameSpecDataSig
	      -> RnM_Fixes s RenamedSpecDataSig

rnSpecDataSig (SpecDataSig tycon ty src_loc)
  = pushSrcLocRn src_loc $
    let
	tyvars = extractMonoTyNames ty
    in
    mkTyVarNamesEnv src_loc tyvars     	`thenRn` \ (tv_env,_) ->
    lookupTyCon tycon			`thenRn` \ tycon' ->
    rnMonoType tv_env ty		`thenRn` \ ty' ->
    returnRn (SpecDataSig tycon' ty' src_loc)
\end{code}

%*********************************************************
%*							*
\subsection{Class declarations}
%*							*
%*********************************************************

@rnClassDecl@ uses the `global name function' to create a new
class declaration in which local names have been replaced by their
original names, reporting any unknown names.

\begin{code}
rnClassDecl :: RdrNameClassDecl -> RnM_Fixes s RenamedClassDecl

rnClassDecl (ClassDecl context cname tyvar sigs mbinds pragmas src_loc)
  = pushSrcLocRn src_loc $
    mkTyVarNamesEnv src_loc [tyvar]	`thenRn` \ (tv_env, [tyvar']) ->
    rnContext tv_env context	    	`thenRn` \ context' ->
    lookupClass cname		    	`thenRn` \ cname' ->
    mapRn (rn_op cname' tv_env) sigs    `thenRn` \ sigs' ->
    rnMethodBinds cname' mbinds    	`thenRn` \ mbinds' ->
    ASSERT(isNoClassPragmas pragmas)
    returnRn (ClassDecl context' cname' tyvar' sigs' mbinds' NoClassPragmas src_loc)
  where
    rn_op clas tv_env (ClassOpSig op ty pragmas locn)
      = pushSrcLocRn locn $
	lookupClassOp clas op		`thenRn` \ op_name ->
	rnPolyType tv_env ty		`thenRn` \ new_ty  ->

{-
*** Please check here that tyvar' appears in new_ty ***
*** (used to be in tcClassSig, but it's better here)
***	    not_elem = isn'tIn "tcClassSigs"
***	    -- Check that the class type variable is mentioned
***	checkTc (clas_tyvar `not_elem` extractTyVarTemplatesFromTy local_ty)
***		(methodTypeLacksTyVarErr clas_tyvar (_UNPK_ op_name) src_loc) `thenTc_`
-}

	ASSERT(isNoClassOpPragmas pragmas)
	returnRn (ClassOpSig op_name new_ty noClassOpPragmas locn)
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************


@rnInstDecl@ uses the `global name function' to create a new of
instance declaration in which local names have been replaced by their
original names, reporting any unknown names.

\begin{code}
rnInstDecl :: RdrNameInstDecl -> RnM_Fixes s RenamedInstDecl

rnInstDecl (InstDecl cname ty mbinds from_here modname uprags pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupClass cname 		     	`thenRn` \ cname' ->

    rnPolyType [] ty			`thenRn` \ ty' ->
	-- [] tv_env ensures that tyvars will be foralled

    rnMethodBinds cname' mbinds		`thenRn` \ mbinds' ->
    mapRn (rn_uprag cname') uprags	`thenRn` \ new_uprags ->

    ASSERT(isNoInstancePragmas pragmas)
    returnRn (InstDecl cname' ty' mbinds'
		       from_here modname new_uprags noInstancePragmas src_loc)
  where
    rn_uprag class_name (SpecSig op ty using locn)
      = pushSrcLocRn src_loc $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	rnPolyType nullTyVarNamesEnv ty	`thenRn` \ new_ty ->
	rn_using using			`thenRn` \ new_using ->
	returnRn (SpecSig op_name new_ty new_using locn)

    rn_uprag class_name (InlineSig op locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (InlineSig op_name locn)

    rn_uprag class_name (DeforestSig op locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (DeforestSig op_name locn)

    rn_uprag class_name (MagicUnfoldingSig op str locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (MagicUnfoldingSig op_name str locn)

    rn_using Nothing 
      = returnRn Nothing
    rn_using (Just v)
      = lookupValue v	`thenRn` \ new_v ->
	returnRn (Just new_v)
\end{code}

%*********************************************************
%*							*
\subsection{@SPECIALIZE instance@ user-pragmas}
%*							*
%*********************************************************

\begin{code}
rnSpecInstSig :: RdrNameSpecInstSig
	      -> RnM_Fixes s RenamedSpecInstSig

rnSpecInstSig (SpecInstSig clas ty src_loc)
  = pushSrcLocRn src_loc $
    let
	tyvars = extractMonoTyNames ty
    in
    mkTyVarNamesEnv src_loc tyvars     	`thenRn` \ (tv_env,_) ->
    lookupClass clas			`thenRn` \ new_clas ->
    rnMonoType tv_env ty		`thenRn` \ new_ty ->
    returnRn (SpecInstSig new_clas new_ty src_loc)
\end{code}

%*********************************************************
%*							*
\subsection{Default declarations}
%*							*
%*********************************************************

@rnDefaultDecl@ uses the `global name function' to create a new set
of default declarations in which local names have been replaced by
their original names, reporting any unknown names.

\begin{code}
rnDefaultDecl :: [RdrNameDefaultDecl] -> RnM_Fixes s [RenamedDefaultDecl]

rnDefaultDecl [] = returnRn []
rnDefaultDecl [DefaultDecl tys src_loc]
  = pushSrcLocRn src_loc $
    mapRn (rnMonoType nullTyVarNamesEnv) tys `thenRn` \ tys' ->
    returnRn [DefaultDecl tys' src_loc]
rnDefaultDecl defs@(d:ds)
  = addErrRn (dupDefaultDeclErr defs) `thenRn_`
    rnDefaultDecl [d]
\end{code}

%*************************************************************************
%*									*
\subsection{Fixity declarations}
%*									*
%*************************************************************************

\begin{code}
rnFixes :: [RdrNameFixityDecl]  -> RnM s [RenamedFixityDecl]

rnFixes fixities
  = mapRn rn_fixity fixities	`thenRn` \ fixes_maybe ->
    returnRn (catMaybes fixes_maybe)
  where
    rn_fixity fix@(InfixL name i)
      = rn_fixity_pieces InfixL name i fix
    rn_fixity fix@(InfixR name i)
      = rn_fixity_pieces InfixR name i fix
    rn_fixity fix@(InfixN name i)
      = rn_fixity_pieces InfixN name i fix

    rn_fixity_pieces mk_fixity name i fix
      = lookupValueMaybe name	`thenRn` \ maybe_res ->
	case maybe_res of
	  Just res | isLocallyDefined res
	    -> returnRn (Just (mk_fixity res i))
	  _ -> failButContinueRn Nothing (undefinedFixityDeclErr fix)
		
\end{code}

%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnPolyType :: TyVarNamesEnv
	   -> RdrNamePolyType
	   -> RnM_Fixes s RenamedPolyType

rnPolyType tv_env (HsForAllTy tvs ctxt ty)
  = rn_poly_help tv_env tvs ctxt ty

rnPolyType tv_env poly_ty@(HsPreForAllTy ctxt ty)
  = rn_poly_help tv_env forall_tyvars ctxt ty
  where
    mentioned_tyvars = extract_poly_ty_names poly_ty
    forall_tyvars    = mentioned_tyvars `minusList` domTyVarNamesEnv tv_env

------------
extract_poly_ty_names (HsPreForAllTy ctxt ty)
  = extractCtxtTyNames ctxt
    `unionLists`
    extractMonoTyNames ty

------------
rn_poly_help :: TyVarNamesEnv
	     -> [RdrName]
	     -> RdrNameContext
	     -> RdrNameMonoType
	     -> RnM_Fixes s RenamedPolyType

rn_poly_help tv_env tyvars ctxt ty
  = getSrcLocRn 				`thenRn` \ src_loc ->
    mkTyVarNamesEnv src_loc tyvars	 	`thenRn` \ (tv_env1, new_tyvars) ->
    let
	tv_env2 = catTyVarNamesEnvs tv_env1 tv_env
    in
    rnContext tv_env2 ctxt			`thenRn` \ new_ctxt ->
    rnMonoType tv_env2 ty	`thenRn` \ new_ty ->
    returnRn (HsForAllTy new_tyvars new_ctxt new_ty)
\end{code}

\begin{code}
rnMonoType :: TyVarNamesEnv
	   -> RdrNameMonoType
	   -> RnM_Fixes s RenamedMonoType

rnMonoType tv_env (MonoTyVar tyvar)
  = lookupTyVarName tv_env tyvar 	`thenRn` \ tyvar' ->
    returnRn (MonoTyVar tyvar')

rnMonoType tv_env (MonoListTy ty)
  = rnMonoType tv_env ty	`thenRn` \ ty' ->
    returnRn (MonoListTy ty')

rnMonoType tv_env (MonoFunTy ty1 ty2)
  = andRn MonoFunTy (rnMonoType tv_env ty1)
		    (rnMonoType tv_env ty2)

rnMonoType  tv_env (MonoTupleTy tys)
  = mapRn (rnMonoType tv_env) tys `thenRn` \ tys' ->
    returnRn (MonoTupleTy tys')

rnMonoType tv_env (MonoTyApp name tys)
  = let
	lookup_fn = if isAvarid (getLocalName name) 
		    then lookupTyVarName tv_env
  	            else lookupTyCon
    in
    lookup_fn name					`thenRn` \ name' ->
    mapRn (rnMonoType tv_env) tys	`thenRn` \ tys' ->
    returnRn (MonoTyApp name' tys')
\end{code}

\begin{code}
rnContext :: TyVarNamesEnv -> RdrNameContext -> RnM_Fixes s RenamedContext

rnContext tv_env ctxt
  = mapRn rn_ctxt ctxt
  where
    rn_ctxt (clas, tyvar)
     = lookupClass clas	    	    `thenRn` \ clas_name ->
       lookupTyVarName tv_env tyvar `thenRn` \ tyvar_name ->
       returnRn (clas_name, tyvar_name)
\end{code}


\begin{code}
derivingNonStdClassErr clas locn sty
  = ppHang (ppStr "Non-standard class in deriving")
         4 (ppCat [ppr sty clas, ppr sty locn])

dupDefaultDeclErr defs sty
  = ppHang (ppStr "Duplicate default declarations")
         4 (ppAboves (map pp_def_loc defs))
  where
    pp_def_loc (DefaultDecl _ src_loc) = ppr sty src_loc

undefinedFixityDeclErr decl sty
  = ppHang (ppStr "Fixity declaration for unknown operator")
	 4 (ppr sty decl)
\end{code}
