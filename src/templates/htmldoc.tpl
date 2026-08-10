<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8"><title>{page-title} | {site-title}</title>
    {styles}
    {head}
  </head>
  <body class="zd-body">
    {prepend}
    <div class="zigdoc">
      <h2 class="site-title">{site-title}</h2>
      {desc}
      {breadcrumb format="<nav class=\"breadcrumb\">{breadcrumb}{page-title}</nav>"}
      <h1 id="{id}">{page-title}</h1>
      {comment}
      {index format="<nav class=\"index\"><strong>Index</strong>{index}</nav>"}
      {docs}
    </div>
    {append}
  </body>
</html>