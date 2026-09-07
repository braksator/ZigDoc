<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8"><title>{page-title} | {site-title}</title>
    {styles}
    {head}
  </head>
  <body class="zd-body">
    {prepend}
    <div class="zigdoc pkind-{kind} {page-classes}">
      <h2 class="site-title">{site-title}</h2>
      {search}
      {desc}
      {breadcrumb format="<nav class=\"bc\">{breadcrumb}<span>{page-title}</span></nav>"}
      <span class="ptype">{page-vis format="{page-vis} "}{page-type}</span>
      <h1 id="{id}">{page-title}</h1>
      {comment}
      {index format="<nav class=\"index {nav-classes}\"><strong>Index</strong>{index}</nav>"}
      {docs}
    </div>
    {append}
  </body>
</html>