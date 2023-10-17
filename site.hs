{-# LANGUAGE OverloadedStrings #-}

import Text.Pandoc.Definition
  ( Pandoc(..), Block(Header, Plain), Inline(..) )
import Text.Pandoc.Walk (query, walk)
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
      posts <- take 5 <$> loadRecentPosts
      let homeContext =
            listField "posts" context (pure posts)
            <> constField "title" "Home"
            <> context
      pandocCompiler
        >>= loadAndApplyTemplate "templates/index.html" homeContext
        >>= loadAndApplyTemplate "templates/default.html" homeContext
        >>= relativizeUrls

  tags <- buildTags "posts/*" (fromCapture "tags/*.html")

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll ("posts/*" .&&. hasNoVersion)
      tagCloud <- renderTagCloud 80 120 tags
      let archiveContext =
            listField "posts" context (pure posts)
            <> constField "tagCloud" tagCloud
            <> constField "title" "Archive"
            <> context
      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveContext
        >>= loadAndApplyTemplate "templates/default.html" archiveContext
        >>= relativizeUrls

  tagsRules tags $ \tag pattern -> do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll pattern
      let ctx = constField "tag" tag
                <> listField "posts" context (pure posts)
                <> constField "title" (tag <> " posts")
                <> context

      makeItem ""
        >>= loadAndApplyTemplate "templates/tag.html" ctx
        >>= loadAndApplyTemplate "templates/default.html" ctx
        >>= relativizeUrls

  -- a version of the posts to use for "recent posts" list
  match "posts/*" $ version "recent" $ do
    compile $
      pandocCompilerWithTransformM
        defaultHakyllReaderOptions
        defaultHakyllWriterOptions
        (\pandoc -> do
          let
            h1 = maybe [Str "no title"] id . firstHeader $ pandoc
            render f = fmap writePandoc . makeItem . Pandoc mempty . pure . Plain . f
          _ <- render removeFormatting h1 >>= saveSnapshot "title"
          _ <- render id h1 >>= saveSnapshot "fancyTitle"
          pure $ addSectionLinks pandoc
        )

  match "posts/*" $ do
    route $ setExtension "html"
    compile $ do
      posts <- take 5 <$> loadRecentPosts
      let postContext =
            listField "posts" context (pure posts)
            <> tagsField "tags" tags
            <> context

      ident <- getUnderlying
      loadBody (setVersion (Just "recent") ident)
        >>= makeItem
        -- Re-save the content under this identifier (no version).
        -- This is required because atom templates use $url$.
        >>= saveSnapshot "content"  -- re-save the content under this ident
        >>= loadAndApplyTemplate "templates/post.html" postContext
        >>= loadAndApplyTemplate "templates/default.html" postContext
        >>= relativizeUrls

  match "templates/*" $ compile templateCompiler

  create ["atom.xml"] $ do
    route idRoute
    compile $ do
      let feedContext =
            bodyField "description"
            <> context
      posts <- loadAllSnapshots ("posts/*" .&&. hasNoVersion) "content"
        >>= fmap (take 10) . recentFirst
      renderAtom feedConfiguration feedContext posts


loadRecentPosts :: Compiler [Item String]
loadRecentPosts = recentFirst =<< loadAll ("posts/*" .&&. hasVersion "recent")


context :: Context String
context =
  dateField "date" "%Y-%m-%d"
  <> snapshotField "title" "title"
  <> snapshotField "fancyTitle" "fancyTitle"
  <> constField "blogTitle" blogTitle
  <> urlFieldNoVersion "url0"
  <> defaultContext


-- | Get field content from snapshot (at item version "recent")
snapshotField
  :: String           -- ^ Key to use
  -> Snapshot         -- ^ Snapshot to load
  -> Context String   -- ^ Resulting context
snapshotField key snap = field key $ \item ->
  loadSnapshotBody (setVersion (Just "recent") (itemIdentifier item)) snap


-- | Set a url field that looks for url of non-versioned identifier
urlFieldNoVersion :: String -> Context a
urlFieldNoVersion key = field key $ \i -> do
  let ident = setVersion Nothing (itemIdentifier i)
      empty' = fail $ "No route url found for item " <> show ident
  fmap (maybe empty' toUrl) $ getRoute ident


firstHeader :: Pandoc -> Maybe [Inline]
firstHeader (Pandoc _ xs) = go xs
  where
  go [] = Nothing
  go (Header _ _ ys : _) = Just ys
  go (_ : t) = go t


-- yield "plain" terminal inline content; discard formatting
removeFormatting :: [Inline] -> [Inline]
removeFormatting = query f
  where
  f inl = case inl of
    Str s -> [Str s]
    Code _ s -> [Str s]
    Space -> [Space]
    SoftBreak -> [Space]
    LineBreak -> [LineBreak]
    Math _ s -> [Str s]
    RawInline _ s -> [Str s]
    _ -> []


feedConfiguration :: FeedConfiguration
feedConfiguration = FeedConfiguration
  { feedTitle = blogTitle
  , feedDescription = blogDescription
  , feedAuthorName = blogAuthorName
  , feedAuthorEmail = blogAuthorEmail
  , feedRoot = blogRoot
  }


addSectionLinks :: Pandoc -> Pandoc
addSectionLinks = walk f where
  f (Header n attr@(idAttr, _, _) inlines) | n > 1 =
      let link = Link ("", ["section"], []) [Str "§"] ("#" <> idAttr, "")
      in Header n attr (inlines <> [Space, link])
  f x = x
