# Marketing materials

Internal technical-promotional collateral for RepoFabric.

Files:

- `RepoFabric-comparison-onepager.html`, source for the single-page comparison sheet (RepoFabric vs a standard winget REST source server vs standalone rewinged). Leans into Azure and Entra integration, Intune awareness, LAN peer-cache bandwidth savings, and simple operations.
- `RepoFabric-comparison-onepager.pdf`, the rendered one-pager (single Letter page).

To re-render the PDF from the HTML with headless Chrome on Windows, run this single command:

```
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new --disable-gpu --no-pdf-header-footer "--print-to-pdf=docs\marketing\RepoFabric-comparison-onepager.pdf" "file:///C:/DEV/WinGet-RepoSync/docs/marketing/RepoFabric-comparison-onepager.html"
```

The repository README hero image (`docs/repofabric-overview.png`) is rendered from the same HTML. To regenerate it, run this single command:

```
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=FFFFFFFF --window-size=800,1140 --screenshot="docs\repofabric-overview.png" "file:///C:/DEV/WinGet-RepoSync/docs/marketing/RepoFabric-comparison-onepager.html"
```

## Note on repository visibility

This is promotional and competitive-positioning material. If this repository is ever switched to public, you may want to remove this `docs/marketing/` directory first, or move it to a private location.
