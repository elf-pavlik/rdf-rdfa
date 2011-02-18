# RDF::RDFa reader/writer

RDFa parser for RDF.rb.

## DESCRIPTION
RDF::RDFa is an RDFa reader for Ruby using the [RDF.rb](http://rdf.rubyforge.org/) library suite.

## FEATURES
RDF::RDFa parses RDFa into statements or triples.

* Fully compliant XHTML/RDFa 1.1 parser.
* Uses Nokogiri for parsing XHTML
* RDFa tests use SPARQL for most tests due to Rasqal limitations. Other tests compare directly against N-triples.

Install with 'gem install rdf-rdfa'

## Usage
Instantiate a parser and parse source, specifying type and base-URL

    RDF::RDFa::Reader.open("etc/foaf.html") do |reader|
      reader.each_statement do |statement|
        puts statement.inspect
      end
    end

## Dependencies
* [RDF.rb](http://rubygems.org/gems/rdf) (>= 0.3.0)
* [Nokogiri](http://rubygems.org/gems/nokogiri) (>= 1.3.3)

## Documentation
Full documentation available on [RubyForge](http://rdf.rubyforge.org/rdfa)

### Principle Classes
* {RDF::RDFa::Format}
* {RDF::RDFa::Reader}
* {RDF::RDFa::Profile}

### Additional vocabularies
* {RDF::PTR}
* {RDF::RDFA}
* {RDF::XHV}
* {RDF::XML}
* {RDF::XSI}

## TODO
* Add support for LibXML and REXML bindings, and use the best available
* Consider a SAX-based parser for improved performance
* Port SPARQL tests to native SPARQL processor, when one becomes available.
* Add generic XHTML+RDFa Writer

## Resources
* [RDF.rb](http://rdf.rubyforge.org/) 
* [Distiller](http://distiller.kellogg-assoc)
* [Documentation](http://rdf.rubyforge.org/rdfa)
* [History](file:file.History.html)
* [RDFa 1.1 Core](http://www.w3.org/TR/2010/WD-rdfa-core-20100422/         "RDFa 1.1 Core")
* [XHTML+RDFa 1.1 Core](http://www.w3.org/TR/2010/WD-xhtml-rdfa-20100422/  "XHTML+RDFa 1.1 Core")
* [RDFa-test-suite](http://rdfa.digitalbazaar.com/test-suite/              "RDFa test suite")

## LICENSE

(The MIT License)

Copyright (c) 2009-2010 Gregg Kellogg

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## FEEDBACK

* gregg@kellogg-assoc.com
* rubygems.org/rdf-rdfa
* github.com/gkellogg/rdf-rdfa
* gkellogg.lighthouseapp.com for bug reports
* <http://lists.w3.org/Archives/Public/public-rdf-ruby/>