module Europa.CodeGen.Exts
    (module Europa.CodeGen, Code) where

import Europa.CodeGen
import Europa.Core
import Europa.Module
import qualified Europa.Rule as Rule
import qualified Language.Haskell.Exts.Syntax as Hs
import Language.Haskell.Exts.Pretty
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as B
import Data.Char (ord, toUpper)
import Data.List (intercalate, concatMap)


type Em a = a (Id Record) (A Record)

-- External view of record.
type Code = Record

data Record = Rec { rec_name    :: Qid
                  , rec_type    :: Em Expr
                  , rec_code    :: [Hs.Decl] }

instance CodeGen Record where
    type Id Record     = Qid
    type A Record      = Unannot
    type Bundle Record = [Hs.Decl]

    interface = error "Unimplemented."

    coalesce records = concatMap rec_code records ++ [main]
        where main = Hs.FunBind [Hs.Match (!) (Hs.Ident "main") []
                                       Nothing (Hs.UnGuardedRhs checks) (Hs.BDecls [])]
              checks = primitiveVar "runChecks"
                       [Hs.List $ map (var . (.$ "box") . rec_name) records]

    serialize _ (Module mod) decls =
        B.pack $ prettyPrint $
        Hs.Module (!) modname [] Nothing Nothing imports decls
        where imports = [ Hs.ImportDecl (!) (Hs.ModuleName "Europa.Runtime")
                                        False False Nothing Nothing ]
              modname = Hs.ModuleName $ B.unpack $ B.intercalate "." $
                        map upcase $ toList mod

    emit rs@(RS x ty rules) = Rec x ty [function rs, def_ty, def_box]
        where def_ty  = value (x .$ "ty") (code ty)
              def_box = value (x .$ "box")
                                     (primbbox (term ty) (var (x .$ "ty")) (var x))

-- | A similar encoding of names as the z-encoding of GHC. Non-letter
-- | characters are escaped with an x.
xencode :: Qid -> String
xencode qid =
    B.unpack $
     joinQ (qid_qualifier qid) `B.append`
     -- Prepend all idents with an x to avoid clash with runtime functions.
     B.cons 'x' (enc (qid_stem qid)) `B.append`
     joinS (qid_suffix qid)
        where joinQ Root = ""
              joinQ (h :. x) = joinQ h `B.append` upcase x `B.append` "."
              joinS Root = ""
              joinS (h :. x) = joinS h `B.append` "_" `B.append` x
              enc = B.concatMap f where
                  f 'x'  = "xx"
                  f '\'' = "xq"
                  f '_'  = "xu"
                  f x | x >= '0', x <= '9' = 'x' `B.cons` B.singleton x
                      | otherwise = B.singleton x

function :: Em RuleSet -> Hs.Decl
function (RS x _ []) =
    Hs.FunBind [Hs.Match (!) (varName x) [] Nothing (Hs.UnGuardedRhs (primCon x)) (Hs.BDecls [])]
function (RS x _ rs) =
    Hs.FunBind [Hs.Match (!) (varName x) [] Nothing (Hs.UnGuardedRhs rhs) (Hs.BDecls [f])]
    where n = Rule.arity (head rs)
          rhs = foldr primLam
                (application (Hs.Var (Hs.UnQual (Hs.Ident "__")) : variables n))
                (pvariables n)
          f | n > 0     = Hs.FunBind (map clause rs ++ [defaultClause x])
            | otherwise = Hs.FunBind (map clause rs)

clause :: Em TyRule -> Hs.Match
clause rule@(env :@ (lhs :--> rhs)) =
    Hs.Match (!) (Hs.Ident "__") (map (pattern env) (Rule.patterns rule))
          Nothing (Hs.UnGuardedRhs (code rhs)) (Hs.BDecls [])

defaultClause :: Id Record -> Hs.Match
defaultClause x =
    Hs.Match (!) (Hs.Ident "__") [] Nothing (Hs.UnGuardedRhs (primCon x)) (Hs.BDecls [])

value :: Id Record -> Hs.Exp -> Hs.Decl
value x rhs =
    Hs.FunBind [Hs.Match (!) (varName x) [] Nothing (Hs.UnGuardedRhs rhs) (Hs.BDecls [])]


pattern :: Em Env -> Em Expr -> Hs.Pat
pattern env (Var x _) | Map.member x env = pvar x
pattern env expr = case unapply expr of
                     Var x _ : xs -> primAppsP x (map (pattern env) xs)

-- | Turn an expression into object code with types erased.
code :: Em Expr -> Hs.Exp
code (Var x _)            = var x
code (Lam (x ::: ty) t _) = primLam (pvar x) (code t)
code (Lam (Hole ty) t _)  = primLam Hs.PWildCard (code t)
code (Pi (x ::: ty) t _)  = primPi (code ty) (pvar x) (code t)
code (Pi (Hole ty) t _)   = primPi (code ty) Hs.PWildCard (code t)
code (App t1 t2 _)        = primap (code t1) (code t2)
code Type                 = primType

-- | Turn a term into its Haskell representation, including all types.
term :: Em Expr -> Hs.Exp
term (Var x _)     = var (x .$ "box")
term (Lam b t _)   = primTLam b (term t)
term (Pi b t _)    = primTPi  b (term t)
term (App t1 t2 _) = primTApp (term t1) (primUBox (term t2) (code t2))
term Type          = primTType
term Kind          = primTKind

(!) :: Hs.SrcLoc
(!) = Hs.SrcLoc "" 0 0

varName :: Id Record -> Hs.Name
varName x = Hs.Ident $ xencode x

conName :: Id Record -> Hs.Name
conName x = Hs.Ident $ xencode x

-- | Smart variable constructor.
var :: Id Record -> Hs.Exp
var = Hs.Var . Hs.UnQual . varName

pvar :: Id Record -> Hs.Pat
pvar = Hs.PVar . varName

-- | Produce a set of variables x1, ..., xn
variables n = map (var . qid . B.pack . show) [1..n]

pvariables n = map (pvar . qid . B.pack . show) [1..n]

-- | Smart constructor constructor.
con :: Id Record -> Hs.Exp
con = Hs.Con . Hs.UnQual . conName

application :: [Hs.Exp] -> Hs.Exp
application = foldl1 Hs.App

-- | Build a constructor pattern.
papplication :: Id Record -> [Hs.Pat] -> Hs.Pat
papplication c xs = Hs.PApp (Hs.UnQual (conName c)) xs

-- Primitives

primitiveVar s [] = Hs.Var $ Hs.UnQual $ Hs.Ident s
primitiveVar s xs = Hs.Paren $ application $ (Hs.Var $ Hs.UnQual $ Hs.Ident s) : xs

primitiveCon s [] = Hs.Con $ Hs.UnQual $ Hs.Ident s
primitiveCon s xs = Hs.Paren $ application $ (Hs.Con $ Hs.UnQual $ Hs.Ident s) : xs

primap  t1 t2 = primitiveVar "ap"  [t1, t2]
primApp t1 t2 = primitiveCon "App" [t1, t2]
primCon c     = primitiveCon "Con" [Hs.Lit (Hs.String (xencode c))]
primType      = primitiveCon "Type" []
primKind      = primitiveCon "Kind" []

primLam pat t = primitiveCon "Lam" [Hs.Paren (Hs.Lambda (!) [pat] t)]
primPi  dom pat range = primitiveCon "Pi" [dom, Hs.Paren (Hs.Lambda (!) [pat] range)]

primApps c = foldl primApp (primCon c)

typedAbstraction c b t =
    let (pat, ty, ran) =
            case b of
              x ::: ty -> ( pvar (x .$ "box")
                          , ty
                          , Hs.Let (Hs.BDecls [value x (primobj (var (x .$ "box")))]) t )
              Hole ty  -> (Hs.PWildCard, ty, t)
        dom = if isVariable ty
              then term ty else primsbox (term ty) primType (code ty)
    in primitiveCon c [dom, Hs.Paren (Hs.Lambda (!) [pat] ran)]

primTLam       = typedAbstraction "TLam"
primTPi        = typedAbstraction "TPi"
primTApp t1 t2 = primitiveCon "TApp" [t1, t2]
primTType      = primitiveCon "TType" []
primTKind      = primitiveCon "TKind" []

primBox ty_code obj_code = primitiveCon "Box" [ty_code, obj_code]
primUBox ty obj_code     = primitiveCon "UBox" [ty, obj_code]
primbbox ty ty_code obj_code = primitiveVar "bbox" [ty, ty_code, obj_code]
primsbox ty ty_code obj_code = primitiveVar "sbox" [ty, ty_code, obj_code]

primobj t = primitiveVar "obj" [t]

primtypeOf t = primitiveVar "typeOf" [t]

-- | Build a pattern matching a constant.
primConP c = Hs.PParen $ Hs.PApp (Hs.UnQual $ Hs.Ident "Con") [Hs.PLit (Hs.String (xencode c))]
primAppP t1 t2 = Hs.PParen $ Hs.PApp (Hs.UnQual $ Hs.Ident "App") [t1, t2]
primAppsP c = foldl primAppP (primConP c)

-- | Upcase a word.
upcase :: B.ByteString -> B.ByteString
upcase s = case B.uncons s of
             Nothing -> ""
             Just (x, xs) -> toUpper x `B.cons` xs
