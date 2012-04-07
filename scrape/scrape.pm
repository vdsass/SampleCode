#!/usr/bin/perl
package SCRAPE;

use strict;
use warnings;
use Data::Dumper;

BEGIN {
unshift (@INC, "$ENV{'SCRAPE_PATH'}/common");
}

my $base_url   = "http://www.scrape.com/applications/";
my $base_url_2 = "http://www.scrape.com/";

my $global_page_count = 0;

my $debug0 = 0;
my $debug_trace = 0;
my $early_exit = 0;
my $debug_dump_products = 0;
my $debug_dump_page = 0;
my $debug_lineArray = 0;
my $debug_pagination = 0;
my $debug_detailsArray = 0;
my $debugProducts = 0;

sub scrape_Generic
{
    my ($url, $prod_ref, $SCRObj) = @_;
    $global_page_count =0;

    warn __LINE__, ": SCRAPE::scrape_Generic Entered\n" if $debug_trace;

    ##fetch the html for the urls ##
    my $product_page = $SCRObj->getProductPage($url, $global_page_count+1);

    ## check if it's a rag link
    if($url =~ /shoplocal/)
    {
      my $module = "SHOPLOCAL_RAGS";
      eval "use $module";
      die "couldn't load module : $!" if ($@);

      &LOCAL_RAGS::parseProductPage(
              $url, $prod_ref, $SCRObj, "230", "-100875", "7d560", "http://shoplocal.com/local", "*");
    }
    else
    {
      if($url =~ /compusa\.com\/applications\/Category\/guidedSearch/i) {
        &SCRAPE::parseProductPage2($product_page, $url, $prod_ref, $SCRObj);
      } else {
      ## parse the html page ##
       &SCRAPE::parseProductPage($product_page, $url, $prod_ref, $SCRObj);
      }
    }
    warn __LINE__, ": SCRAPE::scrape_Generic Exit\n" if $debug_trace;
}

sub parseProductPage2
{
  ## passed in product page ##
  my ($page, $product_url, $prod_ref, $SCRObj) = @_;
  $global_page_count = $global_page_count +1;

  warn __LINE__, ": SCRAPE::parseProductPage2 Enter\n" if $debug_trace;
  warn __LINE__, ": SCRAPE::parseProductPage2 \$product_url=$product_url\n" if $debug_trace;
  warn __LINE__, ": SCRAPE::parseProductPage2 \$global_page_count=$global_page_count\n" if $debug_trace;

  ## create a temporary hash to hold everything ##
  my %products = ();

  ## flag to know when to grab product info ##
  my $active = 0;
  my $in_products_block = 0;

  $page = $SCRObj->normalizePageHTML($page);

  my @lineArray = split(/\n/, $page);

  OUTER_LOOP: for(my $i=0; $i<=$#lineArray; $i++)
  {
    chomp $lineArray[$i];
    warn __LINE__, ": SCRAPE::parseProductPage2:\$lineArray[$i]=$lineArray[$i]\n" if $debug_lineArray;

    ## scan html until you reach the products section
    if($lineArray[$i] =~ /<form name="frmCompare" method="post"/)
    {
      $in_products_block = 1;
    }
    if($in_products_block == 0)
    {
      next;
    }
    if($lineArray[$i] =~ /<div class="product">/i)
    {
      $active = 1;

      if(%products)
      {
        $products{"PageNumber"} = $global_page_count;
        ## insert and reset products hash ##
        $SCRObj->insertProducts($prod_ref, \%products);
        if( $debug_dump_products )
        {
          warn __LINE__, "\n===== insert \%products active loop top =====\n";
          warn __LINE__, "\n: SCRAPE::parseProductPage2:\%products:\n";
          warn __LINE__, Dumper(\%products);
          warn __LINE__, "\n===== insert \%products active loop bottom =====\n";
        }

        %products = ();
      }
    }

    ## look for product data
    if($active == 1)
    {
      if( $lineArray[$i] =~/<a.+?title="Click for more information".+?href="(.+?)">/i )
      {
        $products{"Url"} = $base_url_2 . $1;

        my $details_page = $SCRObj->getProductPage($products{"Url"}, $products{"Title"});
        $details_page    =~ s/[^[:ascii:]]+//g;
        $details_page    = $SCRObj->normalizePageHTML($details_page);

        my @detailsArray = split( '\n', $details_page );

        DETAILS_LOOP: for(my $j=0; $j<=$#detailsArray; $j++)
        {
          chomp $detailsArray[$j];

          if( $debug_detailsArray )
          {
            warn __LINE__, ": SCRAPE::parseProductPage2:active \$detailsArray[$j]=$detailsArray[$j]\n";
            next DETAILS_LOOP if $debug_detailsArray;
          }
          if( $detailsArray[$j] =~ /<div class="prodName"><h1>(.*?) - (.+)<span class="sku">.+?Item#:<.+?>(.+?)<.+?>Model#:<.+?>(.+?)</i )
          {
            $products{"Title"} = $1 if $1;
            $products{"Notes"} = $2 if $2;
            $products{"WebSitePN"} = $3 if $3;
            $products{"MFGPN"} = $4 if $4;

            if( $products{"Notes"} =~ /refurbished/i )
            {
              $products{"Notes"} = 'Refurbished';
            }
            else
            {
              $products{"Notes"} = '';
            }

            $products{"WebSitePN"} =~ s/\|//g;  # remove vertical bar
            $products{"WebSitePN"} =~ s/^\s+//; # trim whitespace
            $products{"WebSitePN"} =~ s/\s+$//; # trim whitespace

            if( $debugProducts )
            {
              warn "\$products{\"Title\"}=$products{\"Title\"}\n" if exists $products{"Title"};
              warn "\$products{\"Notes\"}=$products{\"Notes\"}\n" if exists $products{"Notes"};
              warn "\$products{\"WebSitePN\"}=$products{\"WebSitePN\"}\n" if exists $products{"WebSitePN"};
              warn "\$products{\"MFGPN\"}=$products{\"MFGPN\"}\n" if exists $products{"MFGPN"};
            }
          }

          if($detailsArray[$j] =~ /Price:<\/td>\s+<td width="110" class="font_right_size2" align="right">\$(.+?) /i){
            $products{"Price1"} = $1;
            $products{"Price1"} =~ s/[^\d\.]//ig; # preserve numeric and decimal
          }
          if( $detailsArray[$j] =~ /<sup>\$<\/sup>(.+)<sup><span class="priceDecimalMark">\.<\/span>(.+)<\/sup>/i )
          {
            my $dollars = $1 if $1;
            my $cents   = $2 if $2;

            $products{"Price1"} = $dollars . '.' . $cents if $dollars and $cents;
            $products{"Price2"} = $products{"Price1"};

            if( $debugProducts )
            {
              warn "\$products{\"Price1\"}=$products{\"Price1\"}\n" if exists $products{"Price1"};
              warn "\$products{\"Price2\"}=$products{\"Price2\"}\n" if exists $products{"Price2"};
            }
          }

          ### shopping cart price ###
          if($detailsArray[$j] =~ /<span class="font_right_size3"><strong>\$(.+?)</i){
            $products{"Price1"} = $1;
            $products{"Price1"} =~ s/[^\d\.]//ig;
            if(!$products{"Price2"}) {
              $products{"Price2"} = $products{"Price1"};
            }
          }

          if( $detailsArray[$j] =~ /<a href="javascript:showMyPrice(.+)/i )
          {
            my @elements = split(',', $1);
            $products{"Price1"} = $elements[$#elements-2];
            $products{"Price1"} =~ s/[^\d\.]//ig; # preserve numeric and decimal
          }

          if($detailsArray[$j] =~/List Price:<\/td>\s+<td width="110" class="font_right_size2" align="right">\$([\d\.,]+)/) {  #"
            $products{"Price2"} = $1;
            $products{"Price2"} =~ s/,//g;
          }

          # <dd class="priceSave"> -$49.98 (9%) </dd>
          if($detailsArray[$j] =~ /<dd class="priceSave"> -\$(.+?)\(.+?</i )
          {
            $products{"Rebate_Instant"} = $1;
            $products{"Rebate_Instant"} =~ s/[^\d.]//g if exists $products{"Rebate_Instant"};
          }

          if($detailsArray[$j] =~ /Instant Savings:<\/td>\s+<td width="110" class="font_right_size2" align="right">\s+\-\s+\$(.+?)\s+/) {
            $products{"Rebate_Instant"} = $1;
            $products{"Rebate_Instant"} =~ s/,//g;
            #rebate is for mail in rebates only
            #$products{"Rebate"} = 'Less Rebate: $' . $1;
          }


          if( $detailsArray[$j] =~ /<dd><strong class='stockMesg2'>(.+?)\&nbsp;</i )
          {
            my $shippingMsg = $1 if $1;
            $products{"Retail"}       = $shippingMsg;
            $products{"Availability"} = "In Stock" if $shippingMsg =~ /Available/i;
          }

          if($detailsArray[$j] =~ /Availability:<\/td>\s+<td class="font_right_prod">.*?<b>(.+?)</)
          {
            $products{"Availability"} = $1;
          }

          if(!$products{"Availability"} && $detailsArray[$j] =~ />In Stock </i)
          {
            $products{"Availability"} = "In Stock";
          }

          if(!$products{"Availability"} && $detailsArray[$j] =~ /(Usually Ships.+?)</i)
          {
            $products{"Availability"} = $1;
          }

          # in-store availability
          if(!$products{"Retail"} && $detailsArray[$j] =~ /Usually Ships in/i) {
                  $products{"Retail"} = "Online Only";
          }
          if(!$products{"Retail"} && $detailsArray[$j] =~ /Click here for store availability/i) {
                  $products{"Retail"} = "Available In Store";
          }
          if(!$products{"Retail"} && $detailsArray[$j] =~ /Online Only/i) {
                  $products{"Retail"} = "Online Only";
          }

          $products{"Currency"} = "USD";
          $products{"VAT_Percentage"} = "0";
          $products{"VAT_Included"} = "0";

          ##
          if($products{"Availability"} and $products{"Availability"} =~ /out of/i) {
                  $products{"In_Stock"} = "0";
          } else {
                  $products{"In_Stock"} = "1";
          }
        }# PRICE_LOOP

        #exit if $debug_detailsArray and $early_exit;

      }# click for more info ...
    }# active

    ## if on last line save product before exiting loop
    if($i==$#lineArray && %products) {
      $products{PageNumber} = $global_page_count;
      ## insert ##
      $SCRObj->insertProducts($prod_ref, \%products);
      if( $debug_dump_products )
      {
        warn __LINE__, "\n===== insert \%products last top =====\n";
        warn __LINE__, "\n: SCRAPE::parseProductPage2:\%products:\n";
        warn __LINE__, Dumper(\%products);
        warn __LINE__, "\n===== insert \%products last bottom =====\n";
      }
    }
  }# OUTER_LOOP

  ## get the next page and recurse ##
  my $global_page_count_next = $global_page_count + 1;
  if($page =~ /<a class="paginatNext" href="javascript:setPage\($global_page_count_next\);" title="Next">/)
  {
    warn __LINE__, "\n: SCRAPE::parseProductPage2: Entered next page and recurse\n";

    ##
    my $form_page = $global_page_count_next;
    #if($page =~ /<input type="hidden" name="Page" value="(.+?)"/) {
    #	$form_page = $1;
    #}
    my $form_CatId = "";
    if($page =~ /<input type="hidden" name="CatId" value="(.+?)"/) {
            $form_CatId = $1;
    }
    my $form_pageSize = "";
    if($page =~ /<input type="hidden" name="pageSize" value="(.+?)"/) {
            $form_pageSize = $1;
    }
    my $form_sel = "";
    #<input type="hidden" name="sel" id="sel" value="Detail;131_1337_58001_58001"
    if($page =~ /<input type="hidden" name="sel" id="sel" value="(.+?)"/) {
            $form_sel = $1;
    }
    my $post_data = "sel=$form_sel&CatId=$form_CatId&Page=$form_page&pageSize=$form_pageSize&remove=&srt=&lastFilter=&GS_BreadCrumb=";

    warn __LINE__, "\n: SCRAPE::parseProductPage2: \$post_data=$post_data\n";
    sleep(2);
    my $new_page = $SCRObj->getPost($product_url, $post_data, $global_page_count);

    warn __LINE__, "\n: SCRAPE::parseProductPage2: \$new_page:\n";
    warn __LINE__, Dumper($new_page);

    exit if $debug_pagination and $early_exit;

    &SCRAPE::parseProductPage2($new_page, $product_url, $prod_ref, $SCRObj);
  }
  warn __LINE__, ": SCRAPE::parseProductPage2 exited\n"  if $debug_trace;
}# parseProductPage2

## passed in product page ##
sub parseProductPage
{
  my ($page, $url, $prod_ref, $SCRObj) = @_;
  $global_page_count++;

  warn __LINE__, ": SCRAPE::parseProductPage Enter\n" if $debug_trace;
  warn __LINE__, ": SCRAPE::parseProductPage \$url=$url\n" if $debug_trace;
  warn __LINE__, ": SCRAPE::parseProductPage \$global_page_count=$global_page_count\n" if $debug_trace;

  ## create a temporary hash to hold everything ##
  my %products = ();
  my $active = 0;
  my $productCount = 0;
  my $detailsLink;

  my @lineArray = split(/\n/, $page);

  # parsing the catalog page
  OUTER_LOOP: for(my $i=0; $i<=$#lineArray; $i++)
  {
    chomp $lineArray[$i];

    if( $debug_lineArray )
    {
      warn __LINE__, ": SCRAPE::parseProductPage:\$lineArray[$i]=$lineArray[$i]\n";
      #next OUTER_LOOP;
    }
    # on the catalog page there are N product descriptions each delineated by this div
    if($lineArray[$i] =~ /<div class=\"product\">/i )
    {
      $active = 1;
      $productCount++;
      warn __LINE__, "\n: SCRAPE::parseProductPage:\$productCount=$productCount\n\n" if $debug_trace;
      next OUTER_LOOP;
    }

    # We're in the product table - look for each delineated product:
    # <a title="Lenovo ThinkPad 1838-22U Tablet - Android 3.1 Honeycomb, NVIDIA Tegra 2, 1GB Memory, 16GB Storage, 10.1&quot; WXGA Multi-Touch, Dual Cameras"
    #   class="itemImage" href="/applications/SearchTools/item-details.asp?EdpNo=1132139&CatId=6845" title='Click for details'><img src="...
    if($lineArray[$i] =~ /<a title="(.+?) - .+?href="\/(.+?)" title=.+?<\/a>/i and $active )
    {
      $products{"Title"} = $1;
      $products{"Url"}   = $base_url_2 . $2; # product details url

      unless( $2 )
      {
        warn __LINE__, "\n\n: SCRAPE::parseProductPage: PARSE ERROR \$2 undef \$lineArray[$i]=$lineArray[$i]\n\n";
        die;
      }

      my $details_page = $SCRObj->getProductPage($products{"Url"});
      $details_page    = $SCRObj->normalizePageHTML($details_page);
      $details_page    =~ s/[^[:ascii:]]+//g;

      my @detailsArray = split( '\n', $details_page );

      DETAILS_LOOP: for(my $j=0; $j<=$#detailsArray; $j++)
      {
        chomp $detailsArray[$j];

        if( $debug_detailsArray )
        {
          warn __LINE__, ": SCRAPE::parseProductPage:active \$detailsArray[$j]=$detailsArray[$j]\n";
        }

        # On page: Model#: 183822U  |  SKU#: T70-110008
        #<span class="sku"><strong>Item#:</strong>T70-110008 | <strong>Model#:</strong>183822U</span></h1>
        #            <p class="itemModel"><strong>Item#:</strong> T70-110008&nbsp;&nbsp;|&nbsp;&nbsp;<strong>Model#:</strong> 183822U</p>
        #<div class="prodName"><h1>Lenovo ThinkPad 1838-22U Tablet - Android 3.1 Honeycomb, NVIDIA Tegra 2, 1GB Memory, 16GB Storage, 10.1" WXGA Multi-Touch, Dual Cameras<span class="sku"><strong>Item#:</strong>T70-110008 | <strong>Model#:</strong>183822U</span></h1>
        if($detailsArray[$j] =~ />Model#:<.+?>(.+?)</i  )
        {
          $products{"WebSitePN"} = $1;
          $products{"WebSitePN"} =~ s/^\s+//;
          $products{"WebSitePN"} =~ s/\s+$//;
          $products{"WebSitePN"} =~ s/\s\|$//;
        }

        #<strong>SKU#:</strong> T70-110008</span></h1>
        #<div class="prodName"><h1>Lenovo ThinkPad 1838-22U Tablet - Android 3.1 Honeycomb, NVIDIA Tegra 2, 1GB Memory, 16GB Storage, 10.1" WXGA Multi-Touch, Dual Cameras<span class="sku"><strong>Item#:</strong>T70-110008 | <strong>Model#:</strong>183822U</span></h1>
        #                        <span class="sku"><strong>Item#:</strong>T70-110008 |
        if($detailsArray[$j] =~ /<div class="prodName">.+?<span class="sku"><.+?>Item#:<.+?>(.+?)\|/i )
        {
          $products{"MFGPN"} = $1;
          $products{"MFGPN"} =~ s/^\s+//;
          $products{"MFGPN"} =~ s/\s+$//;
        }

        # <dd><strong class='stockMesg3'>Usually Ships within 24 Hours&nbsp;
        if(!$products{"Availability"} && $detailsArray[$j] =~ /(Usually Ships.+?)</i){
          $products{"Availability"} = $1;
          $products{"Availability"} =~ s/^\s+//g;
          $products{"Availability"} =~ s/\s+$//g;
          $products{"Retail"} = $products{"Availability"};
        }

        #<dd class="priceFinal"><span class="salePrice"><span class="salePrice"><sup>$</sup>449<sup><span class="priceDecimalMark">.</span>99</sup></span></span></dd>
        if($detailsArray[$j] =~ /Price:<\/td>\s+<td width="110" class="font_right_size2" align="right">\$(.+?)\s+<\/td>/is)
        {
            $products{"Price1"} = $1;
            $products{"Price1"} =~ s/[^\d\.]//ig; # preserve numeric and decimal
        }
        elsif($detailsArray[$j] =~ /<span class="font_right_size3"><strong>\$(.+)<\/strong><\/span><\/td>/)
        {
           $products{"Price1"} = $1;
           $products{"Price1"} =~ s/[^\d\.]//ig; # preserve numeric and decimal
        }
        #<dd class="priceFinal"><span class="salePrice"><span class="salePrice"><sup>$</sup>449<sup><span class="priceDecimalMark">.</span>99</sup>
        elsif($detailsArray[$j] =~ /<dd class="priceFinal".+?class="salePrice"><sup>\$<\/sup>(.+?)<sup><span class="priceDecimalMark">\.<\/span>(.+?)<\/sup>/i )
        {
           $products{"Price1"} = $1 . '.' . $2;
           $products{"Price1"} =~ s/[^\d.]//g; # preserve numeric and decimal
        }
        # retail price
        #<dt class="priceList">List Price:</dt>

        if($detailsArray[$j] =~/List Price:<\/td>\s+<td width="110" class="font_right_size2" align="right">\$([\d\.,]+)/)
        {#"
          $products{"Price2"} = $1;
          $products{"Price2"} =~ s/,//g;
        }
        elsif($details_page =~ /<td width="110" class="font_right_size2" align="right">\$([\d,\.]+)/)
        {
          $products{"Price2"} = $1;
          $products{"Price2"} =~ s/[^\d\.]//ig; # preserve numeric and decimal
        }

        #<dd class="priceList">$499.99</dd>
        if( $detailsArray[$j] =~ /<dd class="priceList">\$(.+?)<\/dd>/i )
        {
          $products{"Price2"} = $1;
          $products{"Price2"} =~ s/[^\d.]//g; # preserve numeric and decimal
        }

        if( $detailsArray[$j] =~ /Instant Savings:<\/td>/i )
        {
          if( $detailsArray[$j+1] =~ /<dd class="priceSave">.+?\$(.+?) .+? <\/dd>/i )
          {
            $products{"Rebate_Instant"} = $1;
            $products{"Rebate_Instant"} =~ s/[^\d.]//g;
          }
          else
          {
            $products{"Rebate_Instant"} = 0;
          }
        }

        # in-store availability
        if(!$products{"Retail"} && $detailsArray[$j] =~ /Usually Ships in/) {
          $products{"Retail"} = "Online Only";
        }
        if(!$products{"Retail"} && $detailsArray[$j] =~ /Click here for store availability/i) {
          $products{"Retail"} = "Available In Store";
        }
        if(!$products{"Retail"} && $detailsArray[$j] =~ /Online Only/i) {
          $products{"Retail"} = "Online Only";
        }

        $products{"Currency"}       = "USD";
        $products{"VAT_Percentage"} = "0";
        $products{"VAT_Included"}   = "0";

        ##
        if($products{"Availability"} && $products{"Availability"} =~ /out of/i) {
          $products{"In_Stock"} = "0"; ## yes
        } else {
          $products{"In_Stock"} = "1"; ## no
        }

      }# end DETAILS_LOOP

      ### do db insert ##
      $products{"PageNumber"} = $global_page_count;
      $SCRObj->insertProducts($prod_ref, \%products);

      if( $debug_dump_products )
      {
        warn __LINE__, "\n===== insert \%products active loop top =====\n";
        warn __LINE__, "\n: SCRAPE::parseProductPage:\%products:\n";
        warn __LINE__, Dumper(\%products);
        warn __LINE__, "\n===== insert \%products active loop bottom) =====\n";
      }

      #exit if $early_exit;

      $active = 0;
      %products = ();

    } ## end detailed product info gathering ##
  }# OUTER_LOOP

  #
  # on the reference page there is an href to the "Next page" ...
  # ... on the final page there is no "Next page"
  #
  #<a title="Next page" class="paginatNext" href="/applications/category/category_slc.asp?page=2&Nav=|c:6845|&Sort=0&Recs=10"><img src="http://images.highspeedbackbone.net/td/paginate-next.gif" align="absmiddle" border="0" alt="Next" /></a>
  if( $page =~ /<a title="Next page" class="paginatNext".+?href="\/(.+?)">/i )
  {
    sleep(3);

    my $next_page = $global_page_count + 1;
    my $link  = $base_url_2 . $1;

    if( $debug_pagination )
    {
      warn __LINE__, ": SCRAPE::parseProductPage: next page C Enter\n";
      warn __LINE__, ": SCRAPE::parseProductPage: \$link=$link\n";

      #warn __LINE__, "\n===== next page C top =====\n";
      #warn __LINE__, "\n: SCRAPE::parseProductPage:\$SCRObj:\n";
      #warn __LINE__, Dumper(\$SCRObj);
      #warn __LINE__, "\n===== next page C bottom) =====\n";

      exit if $global_page_count > 2 && $early_exit;
    }

    my $page = $SCRObj->getProductPage($link, $next_page);
    @_ = ($page, $link, $prod_ref, $SCRObj);
    goto &SCRAPE::parseProductPage;
  }
  else
  {
    warn __LINE__, "\n: SCRAPE::parseProductPage: finished catalog pages\n" if $debug_trace;

    if( $debug_dump_page )
    {
      warn __LINE__, "\n===== skipped next page top =====\n";
      warn __LINE__, "\n: SCRAPE::parseProductPage:\$page:\n";
      warn __LINE__, Dumper($page);
      warn __LINE__, "\n===== skipped next page bottom) =====\n";
    }

  }
  warn __LINE__, ": SCRAPE::parseProductPage exited\n" if $debug_trace;
}# parseProductPage
1;
