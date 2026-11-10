<?php
/* Sample content for the template site, run with wp eval-file. */
for ($i = 1; $i <= 10; $i++) {
    wp_insert_post([
        'post_title' => "Benchmark article $i",
        'post_name' => "article-$i",
        'post_status' => 'publish',
        'post_content' => str_repeat("<!-- wp:paragraph --><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Article $i.</p><!-- /wp:paragraph -->\n", 8),
    ]);
}
if (class_exists('WC_Product_Simple')) {
    for ($i = 1; $i <= 12; $i++) {
        $product = new WC_Product_Simple();
        $product->set_name("Product $i");
        $product->set_slug("product-$i");
        $product->set_status('publish');
        $product->set_regular_price((string) (10 + $i));
        $product->set_description("Description of product $i.");
        $product->save();
    }
}
