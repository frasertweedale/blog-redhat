{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import Data.Semigroup ((<>))

import Text.Pandoc.Definition (Pandoc(..), Block(Header, Plain))
import Hakyll


main :: IO ()
main = hakyll $ do
  match "images/*" $ do
    route idRoute
    compile copyFileCompiler

  match "css/*" $ do
    route idRoute
    compile compressCssCompiler

  match "index.rst" $ do
    route $ setExtension "html"
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*.rst"
      let homeContext =
            listField "posts" context (pure $ take 5 posts)
            `mappend` constField "title" "Home"
            `mappend` context
      pandocCompiler
        >>= loadAndApplyTemplate "templates/index.html" homeContext
        >>= loadAndApplyTemplate "templates/default.html" homeContext
        >>= relativizeUrls

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*.rst"
      let archiveContext =
            listField "posts" context (pure posts)
            `mappend` constField "title" "Archive"
            `mappend` context
      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveContext
        >>= loadAndApplyTemplate "templates/default.html" archiveContext
        >>= relativizeUrls

  match "posts/*.rst" $ do
    route $ setExtension "html"
    compile $ do
      getResourceBody >>= saveSnapshot "source"
      pandocCompiler
        >>= loadAndApplyTemplate "templates/default.html" context
        >>= relativizeUrls

  match "templates/*" $ compile templateCompiler


context :: Context String
context =
  dateField "date" "%Y-%m-%d"
  `mappend` headerField "title" "source"
  `mappend` constField "blogTitle" "Fraser's IdM Blog"
  `mappend` defaultContext


-- | Parse the item with Pandoc and pull out the first header
-- Requires a snapshot named @"source"@, taken before any
-- compilation, e.g.:
--
-- @
-- do
--   getResourceBody >>= saveSnapshot "source"
--   pandocCompiler >>= loadAndApplyTemplate ...
-- @
--
headerField
  :: String           -- ^ Key to use
  -> Snapshot         -- ^ Snapshot to load
  -> Context String   -- ^ Resulting context
headerField key snap = field key $ \item -> do
  doc <- readPandoc =<< loadSnapshot (itemIdentifier item) snap
  maybe
    (fail $ "no header found in " <> show (itemIdentifier item))
    (fmap (itemBody . writePandoc) . makeItem)
    (firstHeader (itemBody doc))
  where
    firstHeader (Pandoc _ xs) = firstHeader' xs
    firstHeader' [] = Nothing
    firstHeader' (Header _ _ ys : _) = Just (Pandoc mempty [Plain ys])
    firstHeader' (_ : xs) = firstHeader' xs
