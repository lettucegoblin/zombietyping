# City generator prototype (Python, throwaway)

`python3 citygen.py <seed>` -> `city_<seed>.svg`

Pipeline: district seeds (noisy Voronoi + majority smoothing) -> arterials (MST over
district centers, L-shaped) -> per-district local grid (own spacing/offset) ->
prune segments (keeps connectivity) + cul-de-sacs in residential -> blocks (flood fill)
-> lots (district lot size, must front a road) -> buildings named <district letter><n>.
Red dots = graph nodes (intersections / dead ends). This is the reference for the
GDScript port; see the design discussion in the chat log for the open questions.
