{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

module Binah.CodeGen.Parser
  ( parse
  )
where

import           Control.Monad                  ( void )
import           Data.Char
import           Data.Either
import           Data.Void
import           Text.Megaparsec         hiding ( parse )
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as L
import           Data.Text                      ( Text )
import qualified Data.Text                     as T

import           Binah.CodeGen.Ast

type Parser = Parsec Void Text

parse :: FilePath -> Text -> Either (ParseErrorBundle Text Void) Binah
parse = runParser (binahP <* eof)

binahP :: Parser Binah
binahP =
  L.nonIndented scn (Binah <$> many (predDeclP <|> recDeclP <|> policyDeclP) <*> optional inlineP)

inlineP :: Parser String
inlineP = L.symbol scn "#inline" *> many (notFollowedBy eof *> satisfy (const True))

--------------------------------------------------------------------------------
-- | Predicate Decl
--------------------------------------------------------------------------------

predDeclP :: Parser Decl
predDeclP = L.lineFold scn $ \sc' -> do
  let symbol = L.symbol sc'
  symbol "predicate"
  name <- var sc'
  symbol "::"
  argtys <- someTill (tycon sc' <* arrow sc') $ string "Bool"
  scn
  return . PredDecl $ Pred name argtys

--------------------------------------------------------------------------------
-- | Policy Decl
--------------------------------------------------------------------------------

policyDeclP :: Parser Decl
policyDeclP = L.lineFold scn $ \sc' -> do
  let symbol = L.symbol sc'
  symbol "policy"
  name <- policyVar sc'
  symbol "="
  p <- policyP sc'
  scn
  return $ PolicyDecl name p

--------------------------------------------------------------------------------
-- | Record Decl
--------------------------------------------------------------------------------

recDeclP :: Parser Decl
recDeclP = L.lineFold scn $ \sc' -> do
  name    <- tycon sc
  fields  <- some (try (sc' >> fieldP))
  asserts <- many (try (sc' >> assertP))
  insert  <- optional (try (sc' >> insertPolicyP))
  update  <- many (try (sc' >> updatePolicyP))
  scn
  return $ RecDecl (Rec name fields asserts insert update)

fieldP :: Parser Field
fieldP = Field <$> var sc <*> tycon sc <*> optional fieldPolicyP

fieldPolicyP :: Parser PolicyAttr
fieldPolicyP = policyRefP <|> inlinePolicyP

assertP :: Parser Assert
assertP = do
  symbol "assert"
  Assert <$> between (symbol "[") (symbol "]") (reft scn)
  where symbol = L.symbol sc

insertPolicyP :: Parser PolicyAttr
insertPolicyP = L.symbol sc "insert" >> (policyRefP <|> inlinePolicyP)

updatePolicyP :: Parser UpdatePolicy
updatePolicyP = do
  L.symbol sc "update"
  fields <- fieldPatternP
  policy <- policyRefP <|> inlinePolicyP
  return $ UpdatePolicy fields policy

-- TODO: Implement wildcard
fieldPatternP :: Parser [String]
fieldPatternP = fieldListP <|> pure <$> var sc

fieldListP :: Parser [String]
fieldListP = between (symbol "[") (symbol "]") (var scn `sepBy` symbol ",")
  where symbol = L.symbol scn

--------------------------------------------------------------------------------
-- | Policies
--------------------------------------------------------------------------------

policyRefP :: Parser PolicyAttr
policyRefP = PolicyRef <$> (char '@' *> policyVar sc)

inlinePolicyP :: Parser PolicyAttr
inlinePolicyP = InlinePolicy <$> between (symbol "{") (symbol "}") (policyP scn)
  where symbol = L.symbol sc

policyP :: Parser () -> Parser Policy
policyP sc' = do
  let symbol = L.symbol sc'
  symbol "\\"
  args <- someTill (var sc') $ arrow sc'
  body <- reft (try sc' <|> sc)
  scn
  return $ Policy args body

--------------------------------------------------------------------------------
-- | Refinements
--------------------------------------------------------------------------------

-- We do a very basic parsing of refinements which is enough to insert entityVal 
-- when needed.

ascSymbols :: String
ascSymbols = "!#$%&⋆+./<=>?@\\^|-~:"

op :: Parser () -> Parser String
op sc = L.lexeme sc $ some (oneOf ascSymbols <|> symbolChar)

reft :: Parser () -> Parser Reft
reft sc = uncurry ROps <$> reftApp sc `sepBy1_` op sc

reftApp :: Parser () -> Parser Reft
reftApp sc = RApp <$> some (reftConst sc <|> reftParen sc)

reftConst :: Parser () -> Parser Reft
reftConst sc' = RConst <$> some (satisfy p) <* sc'
  where p c = not (isSpace c || isSymbol c || c `elem` ascSymbols ++ "()][{}")

reftParen :: Parser () -> Parser Reft
reftParen sc = RParen <$> between (symbol "(") (symbol ")") (reft sc) where symbol = L.symbol sc

--------------------------------------------------------------------------------
-- | Identifiers
--------------------------------------------------------------------------------

-- TODO: We should put other reserved words here as well
reserved :: Parser Text
reserved = "assert" <|> "deriving" <|> "insert" <|> "update"

largeid :: Parser String
largeid = (:) <$> upperChar <*> many (alphaNumChar <|> char '\'')

smallid :: Parser String
smallid = do
  notFollowedBy reserved
  (:) <$> lowerChar <*> many (alphaNumChar <|> char '\'')

tycon :: Parser () -> Parser String
tycon sc = L.lexeme sc largeid <?> "type constructor"

var :: Parser () -> Parser String
var sc = L.lexeme sc smallid <?> "variable"

policyVar :: Parser () -> Parser String
policyVar sc = L.lexeme sc largeid <?> "policy name"

--------------------------------------------------------------------------------
-- | Spaces
--------------------------------------------------------------------------------

lineComment :: Parser ()
lineComment = L.skipLineComment "--"

scn :: Parser ()
scn = L.space space1 lineComment empty

sc :: Parser ()
sc = L.space (void $ some (char ' ' <|> char '\t')) lineComment empty

--------------------------------------------------------------------------------
-- | Misc
--------------------------------------------------------------------------------

arrow :: Parser () -> Parser Text
arrow sc = L.symbol sc "->"

sepBy1_ :: Parser a -> Parser sep -> Parser ([a], [sep])
sepBy1_ p sep = do
  x        <- p
  (ys, xs) <- unzip <$> many ((,) <$> sep <*> p)
  return (x : xs, ys)
