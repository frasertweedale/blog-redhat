{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import Data.Semigroup ((<>))

import Text.Pandoc.Definition (Pandoc(..), Block(Header, Plain))
import Hakyll


blogTitle, blogDescription, blogAuthorName, blogAuthorEmail, blogRoot :: String
blogTitle = "Fraser's IdM Blog"
blogDescription = "Identity management, X.509, security, applied cryptography"
blogAuthorName = "Fraser Tweedale"
blogAuthorEmail = "frase@frase.id.au"
blogRoot = "https://frasertweedale.github.io/blog-redhat"


main :: IO ()
main = hakyll $ do
  match "images/**" $ do
    route idRoute
    compile copyFileCompiler

  match "css/*" $ do
    route idRoute
    compile compressCssCompiler

  match "*asc" $ do
    route idRoute
    compile copyFileCompiler

  match "index.rst" $ do
    route $ setExtension "html"
    compile $ do
      posts <- loadRecentPosts
      let homeContext =
            listField "posts" context (pure posts)
            `mappend` constField "title" "Home"
            `mappend` context
      pandocCompiler
        >>= loadAndApplyTemplate "templates/index.html" homeContext
        >>= loadAndApplyTemplate "templates/default.html" homeContext
        >>= relativizeUrls

  tags <- buildTags "posts/*.rst" (fromCapture "tags/*.html")

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll ("posts/*.rst" .&&. hasNoVersion)
      tagCloud <- renderTagCloud 80 120 tags
      let archiveContext =
            listField "posts" context (pure posts)
            `mappend` constField "tagCloud" tagCloud
            `mappend` constField "title" "Archive"
            `mappend` context
      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveContext
        >>= loadAndApplyTemplate "templates/default.html" archiveContext
        >>= relativizeUrls

  -- a version of the posts to use for "recent posts" list
  match "posts/*.rst" $ version "recent" $ do
    route $ setExtension "html"
    compile $
      getResourceBody >>= saveSnapshot "source"

  tagsRules tags $ \tag pattern -> do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll pattern
      let ctx = constField "tag" tag
                `mappend` listField "posts" context (pure posts)
                `mappend` constField "title" (tag <> " posts")
                `mappend` constField "blogTitle" blogTitle
                `mappend` defaultContext

      makeItem ""
        >>= loadAndApplyTemplate "templates/tag.html" ctx
        >>= loadAndApplyTemplate "templates/default.html" ctx
        >>= relativizeUrls

  match "posts/*.rst" $ do
    route $ setExtension "html"
    compile $ do
      posts <- loadRecentPosts
      let postContext =
            listField "posts" context (pure posts)
            `mappend` tagsField "tags" tags
            `mappend` context

      getResourceBody >>= saveSnapshot "source"
      pandocCompiler
        >>= saveSnapshot "content"
        >>= loadAndApplyTemplate "templates/post.html" postContext
        >>= loadAndApplyTemplate "templates/default.html" postContext
        >>= relativizeUrls

  match "templates/*" $ compile templateCompiler

  create ["atom.xml"] $ do
    route idRoute
    compile $ do
      let feedContext =
            bodyField "description"
            `mappend` context
      posts <- loadAllSnapshots ("posts/*.rst" .&&. hasNoVersion) "content"
        >>= fmap (take 10) . recentFirst
      renderAtom feedConfiguration feedContext posts


loadRecentPosts :: Compiler [Item String]
loadRecentPosts =
  fmap (take 5) . recentFirst =<< loadAll ("posts/*.rst" .&&. hasVersion "recent")


context :: Context String
context =
  dateField "date" "%Y-%m-%d"
  `mappend` headerField "title" "source"
  `mappend` constField "blogTitle" blogTitle
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


feedConfiguration :: FeedConfiguration
feedConfiguration = FeedConfiguration
  { feedTitle = blogTitle
  , feedDescription = blogDescription
  , feedAuthorName = blogAuthorName
  , feedAuthorEmail = blogAuthorEmail
  , feedRoot = blogRoot
  }
