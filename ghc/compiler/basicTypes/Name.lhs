%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[Name]{@Name@: to transmit name info from renamer to typechecker}

\begin{code}
#include "HsVersions.h"

module Name (
	Module(..),

	RdrName(..),
	isUnqual,
	isQual,
	isConopRdr,
	appendRdr,
	rdrToOrig,
	showRdr,
	cmpRdr,

	Name,
	Provenance,
	mkLocalName, isLocalName, 
	mkTopLevName, mkImportedName,
	mkImplicitName,	isImplicitName,
	mkBuiltinName,

	NamedThing(..), -- class
	ExportFlag(..), isExported,

	nameUnique,
	nameOrigName,
	nameOccName,
	nameExportFlag,
	nameSrcLoc,
	isLocallyDefinedName,
	isPreludeDefinedName,

	getOrigName, getOccName, getExportFlag,
	getSrcLoc, isLocallyDefined, isPreludeDefined,
	getLocalName, getOrigNameRdr, ltLexical,

	isOpLexeme, pprOp, pprNonOp,
	isConop, isAconop, isAvarid, isAvarop
    ) where

import Ubiq

import CStrings		( identToC, cSEP )
import Outputable	( Outputable(..) )
import PprStyle		( PprStyle(..), codeStyle )
import Pretty
import PrelMods		( pRELUDE )
import SrcLoc		( mkBuiltinSrcLoc, mkUnknownSrcLoc )
import Unique		( pprUnique, Unique )
import Util		( thenCmp, _CMP_STRING_, panic )
\end{code}

%************************************************************************
%*									*
\subsection[RdrName]{The @RdrName@ datatype; names read from files}
%*									*
%************************************************************************

\begin{code}
type Module = FAST_STRING

data RdrName  = Unqual FAST_STRING
              | Qual Module FAST_STRING

isUnqual (Unqual _) = True
isUnqual (Qual _ _) = False

isQual (Unqual _) = False
isQual (Qual _ _) = True

isConopRdr (Unqual n) = isConop n
isConopRdr (Qual m n) = isConop n

appendRdr (Unqual n) str = Unqual (n _APPEND_ str)
appendRdr (Qual m n) str = Qual m (n _APPEND_ str)

rdrToOrig (Unqual n) = (pRELUDE, n)
rdrToOrig (Qual m n) = (m, n)

cmpRdr (Unqual n1)  (Unqual n2)  = _CMP_STRING_ n1 n2
cmpRdr (Unqual n1)  (Qual m2 n2) = LT_
cmpRdr (Qual m1 n1) (Unqual n2)  = GT_
cmpRdr (Qual m1 n1) (Qual m2 n2) = thenCmp (_CMP_STRING_ m1 m2) (_CMP_STRING_ n1 n2) 

instance Eq RdrName where
    a == b = case (a `cmp` b) of { EQ_ -> True;  _ -> False }
    a /= b = case (a `cmp` b) of { EQ_ -> False; _ -> True }

instance Ord RdrName where
    a <= b = case (a `cmp` b) of { LT_ -> True;	 EQ_ -> True;  GT__ -> False }
    a <	 b = case (a `cmp` b) of { LT_ -> True;	 EQ_ -> False; GT__ -> False }
    a >= b = case (a `cmp` b) of { LT_ -> False; EQ_ -> True;  GT__ -> True  }
    a >	 b = case (a `cmp` b) of { LT_ -> False; EQ_ -> False; GT__ -> True  }

instance Ord3 RdrName where
    cmp = cmpRdr

instance NamedThing RdrName where
    -- We're sorta faking it here
    getName rdr_name
      = Global u rdr_name prov ex [rdr_name]
      where
	u    = panic "NamedThing.RdrName:Unique"
	prov = panic "NamedThing.RdrName:Provenance"
	ex   = panic "NamedThing.RdrName:ExportFlag"

instance Outputable RdrName where
    ppr sty (Unqual n) = pp_name sty n
    ppr sty (Qual m n) = ppBeside (pp_mod sty m) (pp_name sty n)

pp_mod PprInterface        m = ppNil
pp_mod PprForC             m = ppBesides [identToC m, ppPStr cSEP]
pp_mod (PprForAsm False _) m = ppBesides [identToC m, ppPStr cSEP]
pp_mod (PprForAsm True  _) m = ppBesides [ppPStr cSEP, identToC m, ppPStr cSEP]
pp_mod _                   m = ppBesides [ppPStr m, ppChar '.']

pp_name sty n | codeStyle sty = identToC n
              | otherwise     = ppPStr n	      

showRdr sty rdr = ppShow 100 (ppr sty rdr)
\end{code}

%************************************************************************
%*									*
\subsection[Name-datatype]{The @Name@ datatype}
%*									*
%************************************************************************

\begin{code}
data Name
  = Local    Unique
             FAST_STRING
             SrcLoc

  | Global   Unique
             RdrName      -- original name; Unqual => prelude
             Provenance   -- where it came from
             ExportFlag   -- is it exported?
             [RdrName]    -- ordered occurrence names (usually just one);
			  -- first may be *un*qual.

data Provenance
  = LocalDef SrcLoc       -- locally defined; give its source location

  | Imported SrcLoc       -- imported; give the *original* source location
         --  [SrcLoc]     -- any import source location(s)

  | Implicit
  | Builtin
\end{code}

\begin{code}
mkLocalName = Local

mkTopLevName   u orig locn exp occs = Global u orig (LocalDef locn) exp occs
mkImportedName u orig locn exp occs = Global u orig (Imported locn) exp occs

mkImplicitName :: Unique -> RdrName -> Name
mkImplicitName u o = Global u o Implicit NotExported []

mkBuiltinName :: Unique -> Module -> FAST_STRING -> Name
mkBuiltinName u m n = Global u (Unqual n) Builtin NotExported []

	-- ToDo: what about module ???
	-- ToDo: exported when compiling builtin ???

isLocalName (Local _ _ _) = True
isLocalName _ 		= False

isImplicitName (Global _ _ Implicit _ _) = True
isImplicitName _ 		         = False

isBuiltinName  (Global _ _ Builtin  _ _) = True
isBuiltinName  _ 		         = False
\end{code}



%************************************************************************
%*									*
\subsection[Name-instances]{Instance declarations}
%*									*
%************************************************************************

\begin{code}
cmpName n1 n2 = c n1 n2
  where
    c (Local    u1 _ _)	    (Local    u2 _ _)     = cmp u1 u2
    c (Global   u1 _ _ _ _) (Global   u2 _ _ _ _) = cmp u1 u2

    c other_1 other_2		-- the tags *must* be different
      = let tag1 = tag_Name n1
	    tag2 = tag_Name n2
	in
	if tag1 _LT_ tag2 then LT_ else GT_

    tag_Name (Local    _ _ _)	  = (ILIT(1) :: FAST_INT)
    tag_Name (Global   _ _ _ _ _) = ILIT(2)
\end{code}

\begin{code}
instance Eq Name where
    a == b = case (a `cmp` b) of { EQ_ -> True;  _ -> False }
    a /= b = case (a `cmp` b) of { EQ_ -> False; _ -> True }

instance Ord Name where
    a <= b = case (a `cmp` b) of { LT_ -> True;	 EQ_ -> True;  GT__ -> False }
    a <	 b = case (a `cmp` b) of { LT_ -> True;	 EQ_ -> False; GT__ -> False }
    a >= b = case (a `cmp` b) of { LT_ -> False; EQ_ -> True;  GT__ -> True  }
    a >	 b = case (a `cmp` b) of { LT_ -> False; EQ_ -> False; GT__ -> True  }

instance Ord3 Name where
    cmp = cmpName

instance Uniquable Name where
    uniqueOf = nameUnique

instance NamedThing Name where
    getName n = n
\end{code}

\begin{code}
nameUnique (Local    u _ _)     = u
nameUnique (Global   u _ _ _ _) = u

nameOrigName (Local    _ n _)	     = (panic "NamedThing.Local.nameOrigName", n)
nameOrigName (Global   _ orig _ _ _) = rdrToOrig orig

nameOccName (Local    _ n _)	       = Unqual n
nameOccName (Global   _ orig _ _ []  ) = orig
nameOccName (Global   _ orig _ _ occs) = head occs

nameExportFlag (Local    _ _ _)	      = NotExported
nameExportFlag (Global   _ _ _ exp _) = exp

nameSrcLoc (Local  _ _ loc)	              = loc
nameSrcLoc (Global _ _ (LocalDef loc) _ _) = loc
nameSrcLoc (Global _ _ (Imported loc) _ _) = loc
nameSrcLoc (Global _ _ Implicit       _ _) = mkUnknownSrcLoc
nameSrcLoc (Global _ _ Builtin        _ _) = mkBuiltinSrcLoc

isLocallyDefinedName (Local  _ _ _)	           = True
isLocallyDefinedName (Global _ _ (LocalDef _) _ _) = True
isLocallyDefinedName (Global _ _ (Imported _) _ _) = False
isLocallyDefinedName (Global _ _ Implicit     _ _) = False
isLocallyDefinedName (Global _ _ Builtin      _ _) = False

isPreludeDefinedName (Local    _ n _)        = False
isPreludeDefinedName (Global   _ orig _ _ _) = isUnqual orig
\end{code}

\begin{code}
instance Outputable Name where
#ifdef DEBUG
    ppr PprDebug (Local    u n _)     = pp_debug u (ppPStr n)
    ppr PprDebug (Global   u o _ _ _) = pp_debug u (ppr PprDebug o)
#endif
    ppr sty        (Local    u n _)             = pp_name sty n
    ppr PprForUser (Global   u o _ _ []  )      = ppr PprForUser o
    ppr PprForUser (Global   u o _ _ occs)      = ppr PprForUser (head occs)
    ppr PprShowAll (Global   u o prov exp occs) = pp_all o prov exp occs
    ppr sty        (Global   u o _ _ _)         = ppr sty o

pp_debug uniq thing
  = ppBesides [thing, ppStr "{-", pprUnique uniq, ppStr "-}" ]

pp_all orig prov exp occs
  = ppBesides [ppr PprShowAll orig, ppr PprShowAll occs, pp_prov prov, pp_exp exp]

pp_exp NotExported = ppNil
pp_exp ExportAll   = ppPStr SLIT("/EXP(..)")
pp_exp ExportAbs   = ppPStr SLIT("/EXP")

pp_prov Implicit = ppPStr SLIT("/IMPLICIT")
pp_prov Builtin  = ppPStr SLIT("/BUILTIN")
pp_prov _        = ppNil
\end{code}

%************************************************************************
%*									*
\subsection[ExportFlag-datatype]{The @ExportFlag@ datatype}
%*									*
%************************************************************************

The export flag @ExportAll@ means `export all there is', so there are
times when it is attached to a class or data type which has no
ops/constructors (if the class/type was imported abstractly).  In
fact, @ExportAll@ is attached to everything except to classes/types
which are being {\em exported} abstractly, regardless of how they were
imported.

\begin{code}
data ExportFlag
  = ExportAll		-- export with all constructors/methods
  | ExportAbs		-- export abstractly
  | NotExported

isExported a
  = case (getExportFlag a) of
      NotExported -> False
      _		  -> True

#ifdef USE_ATTACK_PRAGMAS
{-# SPECIALIZE isExported :: Class -> Bool #-}
{-# SPECIALIZE isExported :: Id -> Bool #-}
{-# SPECIALIZE isExported :: TyCon -> Bool #-}
#endif
\end{code}

%************************************************************************
%*									*
\subsection{Overloaded functions related to Names}
%*									*
%************************************************************************

\begin{code}
class NamedThing a where
    getName :: a -> Name
\end{code}

\begin{code}
getOrigName	    :: NamedThing a => a -> (Module, FAST_STRING)
getOccName	    :: NamedThing a => a -> RdrName
getExportFlag	    :: NamedThing a => a -> ExportFlag
getSrcLoc	    :: NamedThing a => a -> SrcLoc
isLocallyDefined    :: NamedThing a => a -> Bool
isPreludeDefined    :: NamedThing a => a -> Bool

getOrigName	    = nameOrigName 	   . getName
getOccName	    = nameOccName  	   . getName
getExportFlag	    = nameExportFlag	   . getName
getSrcLoc	    = nameSrcLoc	   . getName
isLocallyDefined    = isLocallyDefinedName . getName
isPreludeDefined    = isPreludeDefinedName . getName

getLocalName :: (NamedThing a) => a -> FAST_STRING
getLocalName = snd . getOrigName

getOrigNameRdr :: (NamedThing a) => a -> RdrName
getOrigNameRdr n | isPreludeDefined n = Unqual str
		 | otherwise          = Qual mod str
  where
    (mod,str) = getOrigName n
\end{code}

@ltLexical@ is used for sorting things into lexicographical order, so
as to canonicalize interfaces.  [Regular @(<)@ should be used for fast
comparison.]

\begin{code}
a `ltLexical` b
  = BIND isLocallyDefined a	_TO_ a_local ->
    BIND isLocallyDefined b	_TO_ b_local ->
    BIND getOrigName a		_TO_ (a_mod, a_name) ->
    BIND getOrigName b		_TO_ (b_mod, b_name) ->
    if a_local || b_local then
       a_name < b_name	-- can't compare module names
    else
       case _CMP_STRING_ a_mod b_mod of
	 LT_  -> True
	 EQ_  -> a_name < b_name
	 GT__ -> False
    BEND BEND BEND BEND

#ifdef USE_ATTACK_PRAGMAS
{-# SPECIALIZE ltLexical :: Class -> Class -> Bool #-}
{-# SPECIALIZE ltLexical :: Id -> Id -> Bool #-}
{-# SPECIALIZE ltLexical :: TyCon -> TyCon -> Bool #-}
#endif
\end{code}

These functions test strings to see if they fit the lexical categories
defined in the Haskell report.  Normally applied as in e.g. @isConop
(getLocalName foo)@

\begin{code}
isConop, isAconop, isAvarid, isAvarop :: FAST_STRING -> Bool

isConop cs
  | _NULL_ cs	= False
  | c == '_'	= isConop (_TAIL_ cs)		-- allow for leading _'s
  | otherwise	= isUpper c || c == ':' 
		  || c == '[' || c == '('	-- [] () and (,,) come is as Conop strings !!!
		  || isUpperISO c
  where					
    c = _HEAD_ cs

isAconop cs
  | _NULL_ cs	= False
  | otherwise	= c == ':'
  where
    c = _HEAD_ cs

isAvarid cs
  | _NULL_ cs	 = False
  | c == '_'	 = isAvarid (_TAIL_ cs)	-- allow for leading _'s
  | isLower c	 = True
  | isLowerISO c = True
  | otherwise    = False
  where
    c = _HEAD_ cs

isAvarop cs
  | _NULL_ cs	 		    = False
  | isLower c    		    = False
  | isUpper c    		    = False
  | c `elem` "!#$%&*+./<=>?@\\^|~-" = True
  | isSymbolISO c		    = True
  | otherwise			    = False
  where
    c = _HEAD_ cs

isSymbolISO c = ord c `elem` (0xd7 : 0xf7 : [0xa1 .. 0xbf])
isUpperISO  c = 0xc0 <= oc && oc <= 0xde && oc /= 0xd7 where oc = ord c
isLowerISO  c = 0xdf <= oc && oc <= 0xff && oc /= 0xf7 where oc = ord c
\end{code}

And one ``higher-level'' interface to those:

\begin{code}
isOpLexeme :: NamedThing a => a -> Bool

isOpLexeme v
  = let str = snd (getOrigName v) in isAvarop str || isAconop str

-- print `vars`, (op) correctly
pprOp, pprNonOp :: (NamedThing name, Outputable name) => PprStyle -> name -> Pretty

pprOp sty var
  = if isOpLexeme var
    then ppr sty var
    else ppBesides [ppChar '`', ppr sty var, ppChar '`']

pprNonOp sty var
  = if isOpLexeme var
    then ppBesides [ppLparen, ppr sty var, ppRparen]
    else ppr sty var

#ifdef USE_ATTACK_PRAGMAS
{-# SPECIALIZE isOpLexeme :: Id -> Bool #-}
{-# SPECIALIZE pprNonOp :: PprStyle -> Id -> Pretty #-}
{-# SPECIALIZE pprNonOp :: PprStyle -> TyCon -> Pretty #-}
{-# SPECIALIZE pprOp :: PprStyle -> Id -> Pretty #-}
#endif
\end{code}
